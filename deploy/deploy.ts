import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

/**
 * Deploys PrivateLogisticsSLA (no constructor args).
 *
 * Usage examples:
 *   yarn hardhat deploy --network sepolia --tags PrivateLogisticsSLA
 *   yarn hardhat deploy --network localhost --tags PrivateLogisticsSLA
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network, run } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  log(`\n🚚 Deploying PrivateLogisticsSLA from ${deployer} on ${network.name}...`);

  const deployed = await deploy("PrivateLogisticsSLA", {
    from: deployer,
    args: [],
    log: true,
    waitConfirmations: network.live ? 3 : 1,
    skipIfAlreadyDeployed: true,
  });

  log(`✅ PrivateLogisticsSLA address: ${deployed.address}`);

  // Optional: verify on block explorer if newly deployed and on live network
  if (network.live && (deployed as any).newlyDeployed) {
    try {
      await run("verify:verify", {
        address: deployed.address,
        constructorArguments: [],
      });
      log("🔎 Verified on block explorer (if supported).");
    } catch (e: any) {
      const msg = e?.message || String(e);
      if (!msg.includes("Already Verified")) {
        log(`⚠️ Verification skipped: ${msg}`);
      } else {
        log("ℹ️ Already verified.");
      }
    }
  }
};

export default func;
func.id = "deploy_private_logistics_sla"; // unique id to avoid re-execution
func.tags = ["PrivateLogisticsSLA", "Logistics", "FHEVM"];
