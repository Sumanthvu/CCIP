const { ethers } = require("hardhat");

// Testnet addresses
const CCIP_ROUTERS = {
  ethereum: "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59", // Sepolia
  polygon: "0x1035CabC275068e0F4b745A29CEDf38E13aF41b1", // Mumbai
  avalanche: "0x554472a2720E5E7D5D3C817529aBA05EEd5F82D8"  // Fuji
};

const VRF_COORDINATORS = {
  ethereum: "0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625", // Sepolia
  polygon: "0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed", // Mumbai
  avalanche: "0x2eD832Ba664535e5886b75D64C46EB9a228C2610" // Fuji
};

const PRICE_FEEDS = {
  ethereum: "0x694AA1769357215DE4FAC081bf1f309aDC325306", // ETH/USD (Sepolia)
  polygon: "0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada", // MATIC/USD (Mumbai)
  avalanche: "0x86d67c3D38D2bCeE722E601025C25a575021c6EA" // AVAX/USD (Fuji)
};

const LINK_TOKENS = {
  ethereum: "0x779877A7B0D9E8603169DdbD7836e478b4624789", // Sepolia
  polygon: "0x326C977E6efc84E512bB9C30f76E30c160eD06FB", // Mumbai
  avalanche: "0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846"  // Fuji
};

const VRF_KEY_HASHES = {
  ethereum: "0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c",
  polygon: "0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f",
  avalanche: "0x354d2f95da55398f44b7cff77da56283d9c6c829a4bdf1bbcaf2ad6a4d081f61"
};

const CHAIN_SELECTORS = {
  ethereum: 16015286601757825753, // Sepolia
  polygon: 12532609583862916517,  // Mumbai
  avalanche: 14767482510784806043 // Fuji
};

async function main() {
  const network = await ethers.provider.getNetwork();
  let chainName;
  
  if (network.chainId === 11155111) chainName = "ethereum"; // Sepolia
  else if (network.chainId === 80001) chainName = "polygon"; // Mumbai
  else if (network.chainId === 43113) chainName = "avalanche"; // Fuji
  else throw new Error("Unsupported network");

  console.log(`Deploying to ${chainName} network...`);

  const TickItOn = await ethers.getContractFactory("TickItOn");
  const tickItOn = await TickItOn.deploy(
    CCIP_ROUTERS[chainName],
    VRF_COORDINATORS[chainName],
    PRICE_FEEDS[chainName],
    LINK_TOKENS[chainName],
    0, // Replace with your VRF subscription ID
    VRF_KEY_HASHES[chainName],
    chainName,
    CHAIN_SELECTORS[chainName]
  );

  await tickItOn.deployed();
  console.log("TickItOn deployed to:", tickItOn.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});