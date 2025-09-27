const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // platform fee örneği: %2 (200 bps), alıcı: deployer
  const feeBps = process.env.FEE_BPS ? parseInt(process.env.FEE_BPS) : 200;
  const feeRecipient = process.env.FEE_RECIPIENT || deployer.address;

  const C = await hre.ethers.getContractFactory("StreamPay");
  const c = await C.deploy(feeBps, feeRecipient);
  await c.waitForDeployment();

  console.log("StreamPay deployed at:", await c.getAddress());
  console.log("FeeBps:", feeBps, "FeeRecipient:", feeRecipient);
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
