// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StreamPay
 * @notice ERC-20 ile PERIYODIK abonelik tahsilatı. Payer, kontrata (EIP-2612 permit ile) allowance verir.
 *         Kontrat her periyotta payer'dan merchant'a transferFrom ile tahsilat yapar.
 *
 * Özellikler:
 * - EIP-2612 permit imzasıyla tek tık yetkilendirme (opsiyonel).
 * - Trial (deneme) ve grace period (esneklik) mantığı.
 * - Payer veya merchant tarafından iptal.
 * - Payer tarafında plan güncelleme (miktar/periyot).
 * - Platform ücreti (owner’a giden) bps ile.
 * - Pausable & ReentrancyGuard (acil durdurma ve güvenlik).
 *
 * Uyarı: Üretim öncesi denetim, limitler, oracle saat kayması toleransı vb. ek kontroller önerilir.
 */
contract StreamPay is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Subscription {
        address payer;          // ödeyen
        address merchant;       // tahsil eden
        IERC20  token;          // ödeme token'ı (USDC gibi)
        uint128 amount;         // periyot başına tahsil edilecek miktar
        uint32  period;         // saniye cinsinden periyot (ör: 30 gün ~ 2592000)
        uint32  nextChargeAt;   // bir sonraki tahsil zamanı (unix)
        uint32  gracePeriod;    // gecikme toleransı (saniye)
        bool    active;         // abonelik aktif mi
    }

    uint256 public nextId;
    mapping(uint256 => Subscription) public subs;

    // platform ücreti: bps (10_000 = %100). Örn: 200 = %2
    uint16 public platformFeeBps;
    address public feeRecipient;

    event SubscriptionCreated(
        uint256 indexed id,
        address indexed payer,
        address indexed merchant,
        address token,
        uint128 amount,
        uint32 period,
        uint32 nextChargeAt,
        uint32 gracePeriod
    );
    event Charged(uint256 indexed id, uint256 cycles, uint256 grossAmount, uint256 feeAmount, uint256 netAmount);
    event Cancelled(uint256 indexed id, address by);
    event Updated(uint256 indexed id, uint128 newAmount, uint32 newPeriod, uint32 newGrace);
    event FeeConfigUpdated(uint16 feeBps, address feeRecipient);
    event Paused();
    event Unpaused();

    constructor(uint16 _feeBps, address _feeRecipient) {
        require(_feeRecipient != address(0), "feeRecipient=0");
        require(_feeBps <= 1000, "fee too high"); // max %10 default sınır
        platformFeeBps = _feeBps;
        feeRecipient = _feeRecipient;
    }

    // ---------- Yönetim ----------

    function setFeeConfig(uint16 _feeBps, address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "feeRecipient=0");
        require(_feeBps <= 2000, "fee too high"); // üst sınırı gerektiğinde artır
        platformFeeBps = _feeBps;
        feeRecipient = _feeRecipient;
        emit FeeConfigUpdated(_feeBps, _feeRecipient);
    }

    function pause() external onlyOwner { _pause(); emit Paused(); }
    function unpause() external onlyOwner { _unpause(); emit Unpaused(); }

    // ---------- Permit Yardımcıları ----------

    /**
     * @dev Payer, imza vererek token'a "StreamPay kontratı harcayabilir" izni verir.
     * token, IERC20Permit desteklemeli (EIP-2612).
     * Öneri: allowance'ı yüksek verin (ör: type(uint256).max) ki tekrar imza gerektirmesin.
     */
    function permitApprove(
        address token,
        address owner_,
        uint256 value,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external whenNotPaused {
        IERC20Permit(token).permit(owner_, address(this), value, deadline, v, r, s);
    }

    // ---------- Abonelik Akışı ----------

    /**
     * @notice Yeni abonelik oluştur.
     * @param token ERC20 token adresi (USDC, USDT vs).
     * @param merchant Tahsilat alacak adres.
     * @param amount Periyot başı tahsil edilecek miktar.
     * @param period Saniye cinsinden periyot (ör: 30 günde bir tahsil için 2592000).
     * @param startAt İlk tahsil tarihi. "trial" için ileri bir tarih verebilirsin.
     * @param grace Esneklik süresi (gecikme toleransı). Örn: 3 gün = 259200.
     */
    function createSubscription(
        address token,
        address merchant,
        uint128 amount,
        uint32 period,
        uint32 startAt,
        uint32 grace
    ) external whenNotPaused returns (uint256 id) {
        require(merchant != address(0), "merchant=0");
        require(amount > 0, "amount=0");
        require(period >= 60, "period too small"); // en az 1 dk (örnek)
        require(startAt >= uint32(block.timestamp), "start in past");

        id = ++nextId;
        subs[id] = Subscription({
            payer: msg.sender,
            merchant: merchant,
            token: IERC20(token),
            amount: amount,
            period: period,
            nextChargeAt: startAt,
            gracePeriod: grace,
            active: true
        });

        emit SubscriptionCreated(id, msg.sender, merchant, token, amount, period, startAt, grace);
    }

    /**
     * @notice Tahsilatı tetikle. Herkes çağırabilir (keeper uyumlu).
     * Bir çağrıda birden fazla periyot (cycle) tahsil eder.
     * @param id Abonelik ID.
     * @param maxCycles Bu çağrıda tahsil edilecek maksimum periyot sayısı (DoS önlemek için sınır).
     */
    function charge(uint256 id, uint8 maxCycles) external whenNotPaused nonReentrant {
        Subscription storage s = subs[id];
        require(s.active, "inactive");
        require(maxCycles > 0 && maxCycles <= 12, "bad maxCycles"); // aynı tx'te en çok 12 periyot

        // Tahsil edilebilir cycle sayısını hesapla
        uint32 nowTs = uint32(block.timestamp);
        require(nowTs + s.gracePeriod >= s.nextChargeAt, "not due");
        if (nowTs < s.nextChargeAt) {
            // daha trial/grace içi ama grace yettiği için 1 cycle ödeyebiliriz
            // yine de cycles hesabı aşağıda korunaklı
        }

        // kaç periyot geçmiş = floor((now - nextChargeAt) / period) + 1
        // ama now < nextChargeAt ise ve grace ile izinliyse en az 1
        uint256 cycles;
        if (nowTs >= s.nextChargeAt) {
            cycles = 1 + (nowTs - s.nextChargeAt) / s.period;
        } else {
            // now < nextChargeAt, ama gracePeriod izin veriyor → 1 cycle
            cycles = 1;
        }
        if (cycles > maxCycles) cycles = maxCycles;

        uint256 gross = uint256(s.amount) * cycles;
        uint256 fee = (gross * platformFeeBps) / 10_000;
        uint256 net = gross - fee;

        // transferFrom payer → merchant ve feeRecipient
        // Kontrat spender olduğu için payer -> merchant/feeRecipient
        s.token.safeTransferFrom(s.payer, s.merchant, net);
        if (fee > 0) {
            s.token.safeTransferFrom(s.payer, feeRecipient, fee);
        }

        // nextChargeAt'i cycles kadar ileri sar
        s.nextChargeAt += uint32(s.period * cycles);

        emit Charged(id, cycles, gross, fee, net);
    }

    /**
     * @notice Aboneliği iptal et (payer veya merchant).
     */
    function cancel(uint256 id) external whenNotPaused {
        Subscription storage s = subs[id];
        require(s.active, "already");
        require(msg.sender == s.payer || msg.sender == s.merchant, "forbidden");
        s.active = false;
        emit Cancelled(id, msg.sender);
    }

    /**
     * @notice Plan güncelle (sadece payer). Bir sonraki tahsilden itibaren geçerli.
     * nextChargeAt korunur, böylece cycle hizası bozulmaz.
     */
    function updatePlan(
        uint256 id,
        uint128 newAmount,
        uint32 newPeriod,
        uint32 newGrace
    ) external whenNotPaused {
        Subscription storage s = subs[id];
        require(s.active, "inactive");
        require(msg.sender == s.payer, "only payer");
        require(newAmount > 0, "amount=0");
        require(newPeriod >= 60, "period too small");
        s.amount = newAmount;
        s.period = newPeriod;
        s.gracePeriod = newGrace;
        emit Updated(id, newAmount, newPeriod, newGrace);
    }

    // Görüntüleme yardımcıları
    function dueInfo(uint256 id) external view returns (
        bool isDue,
        uint256 cyclesOwed,
        uint32 nextAt
    ) {
        Subscription memory s = subs[id];
        if (!s.active) return (false, 0, s.nextChargeAt);
        uint32 nowTs = uint32(block.timestamp);
        if (nowTs + s.gracePeriod < s.nextChargeAt) {
            return (false, 0, s.nextChargeAt);
        }
        uint256 cycles;
        if (nowTs >= s.nextChargeAt) {
            cycles = 1 + (nowTs - s.nextChargeAt) / s.period;
        } else {
            cycles = 1;
        }
        return (true, cycles, s.nextChargeAt);
    }
}
