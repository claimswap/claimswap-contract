import "dotenv/config";
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "hardhat-watcher";
import "hardhat-contract-sizer";
import "@openzeppelin/hardhat-upgrades";
import "@nomiclabs/hardhat-ethers";
import "hardhat-deploy";
import "hardhat-klaytn-patch";

import { HardhatUserConfig } from 'hardhat/types';

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.5.6",
        settings: {
          evmVersion: "constantinople",
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
      {
        version: "0.8.10",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
    ],
    overrides: {
      "contracts/CLS/ClsToken.sol": {
        version: "0.5.14",
        settings: {
          evmVersion: "constantinople",
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
      "contracts/utils/ClsTokenAdjust.sol": {
        version: "0.5.14",
        settings: {
          evmVersion: "constantinople",
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
      "contracts/utils/MockTokenUpgradeable.sol": {
        version: "0.5.14",
        settings: {
          evmVersion: "constantinople",
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
      "contracts/governance/GovernorMultiDelegate.sol": {
        version: "0.5.16",
        settings: {
          evmVersion: "istanbul",
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
      "contracts/governance/GovernorMultiDelegator.sol": {
        version: "0.5.16",
        settings: {
          evmVersion: "istanbul",
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
      "contracts/governance/GovernorMultiInterfaces.sol": {
        version: "0.5.16",
        settings: {
          evmVersion: "istanbul",
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
      "contracts/governance/Timelock.sol": {
        version: "0.5.16",
        settings: {
          evmVersion: "istanbul",
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
    }
  },
  networks: {
    // hardhat: { // https://hardhat.org/hardhat-network/guides/mainnet-forking.html
    //   forking: {
    //     url: "https://eth-mainnet.alchemyapi.io/v2/<key>",
    //     blockNumber: 11321231
    //   }
    // },
    ropsten: {
      url: 'https://ropsten.infura.io/v3/e81fcce544f741798dc16dcb7b33d9d7',
      chainId: 3,
      accounts: [""],
      saveDeployments: false,
      tags: ["test"]
    },
    baobab: {
      url: 'https://kaikas.baobab.klaytn.net:8651',
      chainId: 1001,
      accounts: [""],
      saveDeployments: true,
      tags: ["test"]
    },
    baobabDev: {
      url: 'https://kaikas.baobab.klaytn.net:8651',
      chainId: 1001,
      accounts: [""],
      saveDeployments: true,
      tags: ["staging"]
    },
  },
  typechain: {
    target: "ethers-v5",
    outDir: "typechain/ethers-v5"
  },
  // typechain: {
  //   target: "web3-v1",
  //   outDir: "typechain/web3-v1"
  // },
  watcher: {
    compilation: {
      tasks: ['compile'],
      files: ['./contracts'],
      verbose: true,
    },
    test: {
      tasks: ['compile', 'test'],
      files: ['./contracts', './test'],
      verbose: true
    }
  },
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true,
  },
  namedAccounts: {
    deployer: {
      default: 0
    }
  }
}

export default config;
