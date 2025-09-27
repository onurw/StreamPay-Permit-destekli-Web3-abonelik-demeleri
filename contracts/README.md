# StreamPay — Permit destekli Web3 abonelik ödemeleri

Abonelik (subscription) mantığıyla ERC-20 üzerinden periyodik tahsilat yapar.
Payer, kontrata allowance verir (isteğe bağlı EIP-2612 **permit** imzası ile).
Kontrat her periyotta `transferFrom(payer → merchant)` çalıştırır.

## Özellikler
- EIP-2612 permit imzasıyla tek adımda yetkilendirme
- Trial başlatmak için ileri tarihli `startAt`
- Grace period ile gecikmede de tahsilata izin
- Payer/merchant iptali
- Payer tarafından plan (amount/period/grace) güncelleme
- Platform ücreti (bps) ayarı, Pausable & ReentrancyGuard

## Hızlı Başlangıç
```bash
npm install
npm run build
npm run node
# yeni terminal
npm run deploy:local
