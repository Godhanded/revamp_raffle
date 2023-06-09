const { network } = require("hardhat")
const { developmentChains, networkConfig } = require("../helper-hardhat-config")
const { verify } = require("../utils/verify")

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { log, deploy } = deployments
    const deployer = await getNamedAccounts()
    const chainId = network.config.chainId

    const netArgs = networkConfig[chainId]
    const args = [
        netArgs.vrfCoordinatorV2,
        netArgs.subscriptionId,
        netArgs.gasLane,
        netArgs.interval,
        netArgs.entranceFee,
        netArgs.minimumRafflePayout,
        netArgs.callbackGasLimit,
    ]

    const raffle = await deploy("Raffle", {
        from: deployer,
        args: args,
        log: true,
        waitConfirmations: network.config.blockConfirmations || 1,
    })

    if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
        log("Verifying...")
        await verify(raffle.address, args)
    }
}

module.exports.tags = ["all", "Raffle", "main"]
