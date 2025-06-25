// require("@nomicfoundation/hardhat-toolbox");
// require("dotenv").config();

// module.exports = {
//   solidity: {
//     version: "0.8.28",
//     settings: {
//       optimizer: {
//         enabled: true,
//         runs: 200,
//       },
//       viaIR: true, // ✅ Correctly placed here
//     },
//   },
//   networks: {
//     sepolia: {
//       url: process.env.ALCHEMY_SEPOLIA_URL,
//       accounts: [process.env.PRIVATE_KEY],
//     },
    // polygon_mumbai: {
    //   url: process.env.ALCHEMY_MUMBAI_URL,
    //   accounts: [process.env.PRIVATE_KEY],
    // },
    // avalanche_fuji: {
    //   url: "https://api.avax-test.network/ext/bc/C/rpc",
    //   accounts: [process.env.PRIVATE_KEY],
    // },
//   },
//   etherscan: {
//     apiKey: {
//       sepolia: process.env.ETHERSCAN_API_KEY,
//       polygonMumbai: process.env.POLYGONSCAN_API_KEY,
//     },
//   },
// };

require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.28",
    settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true }
  },
  networks: {
    sepolia: {
      url: process.env.ALCHEMY_SEPOLIA_URL,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 11155111
    },
        polygon_amoy: {
      url: process.env.ALCHEMY_AMOY_URL,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 80002
    },
    avalanche_fuji: {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      accounts: [process.env.PRIVATE_KEY],
      chainId: 43113
    },
    // …other networks…
  },
  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY,     // if you want to verify later
    }
  }
};
