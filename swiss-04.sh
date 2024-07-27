#!/bin/sh

# Function to handle errors
handle_error() {
    echo "Error occurred in script execution. Exiting."
    exit 1
}

# Trap any error
trap 'handle_error' ERR

# Update and upgrade the system
echo "Updating and upgrading the system..."
sudo apt-get update && sudo apt-get upgrade -y
clear

# Install necessary packages and dependencies
echo "Installing necessary packages and dependencies..."
npm install --save-dev hardhat
npm install dotenv
npm install @swisstronik/utils
npm install @openzeppelin/contracts
npm install --save-dev @openzeppelin/hardhat-upgrades
npm install @nomicfoundation/hardhat-toolbox
npm install typescript ts-node @types/node
echo "Installation of dependencies completed."

# Create a new Hardhat project
echo "Creating a new Hardhat project..."
npx hardhat init

# Remove the default Lock.sol contract
echo "Removing default Lock.sol contract..."
rm -f contracts/Lock.sol

# Create .env file
echo "Creating .env file..."
read -p "Enter your private key: " PRIVATE_KEY
echo "PRIVATE_KEY=$PRIVATE_KEY" > .env
echo ".env file created."

# Configure Hardhat
echo "Configuring Hardhat..."
cat << 'EOL' > hardhat.config.ts
import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import dotenv from 'dotenv';
import '@openzeppelin/hardhat-upgrades';

dotenv.config();

const config: HardhatUserConfig = {
  defaultNetwork: 'swisstronik',
  solidity: '0.8.20',
  networks: {
    swisstronik: {
      url: 'https://json-rpc.testnet.swisstronik.com/',
      accounts: [`0x${process.env.PRIVATE_KEY}`],
    },
  },
};

export default config;
EOL
echo "Hardhat configuration completed."

# Collect token details
read -p "Enter the token name: " TOKEN_NAME
read -p "Enter the token symbol: " TOKEN_SYMBOL

# Create the PERC20Sample contract
echo "Creating PERC20Sample.sol contract..."
mkdir -p contracts
cat << EOL > contracts/PERC20Sample.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PERC20Sample is ERC20 {
    constructor() ERC20("$TOKEN_NAME", "$TOKEN_SYMBOL") {
        _mint(msg.sender, 1000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
EOL
echo "PERC20Sample.sol contract created."

# Compile the contract
echo "Compiling the contract..."
npx hardhat compile
echo "Contract compiled."

# Create deploy.ts script
echo "Creating deploy.ts script..."
mkdir -p scripts utils
cat << 'EOL' > scripts/deploy.ts
import { ethers } from 'hardhat'
import fs from 'fs'
import path from 'path'

async function main() {
  const Contract = await ethers.getContractFactory('PERC20Sample')

  console.log('Deploying PERC20 token...')
  const contract = await Contract.deploy()

  await contract.waitForDeployment()
  const contractAddress = await contract.getAddress()
  console.log('PERC20 token deployed to:', contractAddress)

  const deployedAddressPath = path.join(__dirname, '..', 'utils', 'deployed-address.ts')

  const fileContent = `const deployedAddress = '${contractAddress}'\n\nexport default deployedAddress\n`

  fs.writeFileSync(deployedAddressPath, fileContent, { encoding: 'utf8' })
  console.log('Address written to deployed-address.ts')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
})
EOL
echo "deploy.ts script created."

# Create mint.ts script
echo "Creating mint.ts script..."
cat << 'EOL' > scripts/mint.ts
import { ethers, network } from 'hardhat'
import { encryptDataField } from '@swisstronik/utils'
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/src/signers'
import { HttpNetworkConfig } from 'hardhat/types'
import deployedAddress from '../utils/deployed-address'

const sendShieldedTransaction = async (
  signer: HardhatEthersSigner,
  destination: string,
  data: string,
  value: number
) => {
  const rpclink = (network.config as HttpNetworkConfig).url

  const [encryptedData] = await encryptDataField(rpclink, data)

  return await signer.sendTransaction({
    from: signer.address,
    to: destination,
    data: encryptedData,
    value,
  })
}

async function main() {
  const contractAddress = deployedAddress

  const [signer] = await ethers.getSigners()

  const contractFactory = await ethers.getContractFactory('PERC20Sample')
  const contract = contractFactory.attach(contractAddress)

  const functionName = 'mint'
  const recipient = signer.address
  const amount = ethers.parseUnits('1000', 18)
  const setMessageTx = await sendShieldedTransaction(
    signer,
    contractAddress,
    contract.interface.encodeFunctionData(functionName, [recipient, amount]),
    0
  )
  await setMessageTx.wait()

  console.log('Transaction Receipt: ', setMessageTx)
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
EOL
echo "mint.ts script created."

# Create balance-of.ts script
echo "Creating balance-of.ts script..."
cat << 'EOL' > scripts/balance-of.ts
import { ethers, network } from 'hardhat'
import { encryptDataField, decryptNodeResponse } from '@swisstronik/utils'
import { HttpNetworkConfig } from 'hardhat/types'
import deployedAddress from '../utils/deployed-address'
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers'
import { TransactionRequest } from 'ethers'

const sendShieldedQuery = async (wallet: HardhatEthersSigner, destination: string, data: string) => {
  if (!wallet.provider) {
    throw new Error("wallet doesn't contain connected provider")
  }

  const rpclink = (network.config as HttpNetworkConfig).url
  const [encryptedData, usedEncryptedKey] = await encryptDataField(rpclink, data)

  const networkInfo = await wallet.provider.getNetwork()
  const nonce = await wallet.getNonce()

  console.log(networkInfo)

  const callData = {
    to: destination,
    data: encryptedData,
    nonce: nonce,
    chainId: 1291,
    gasLimit: 200000,
    gasPrice: 0,
  } as TransactionRequest

  const response = await wallet.provider.call(callData)

  return await decryptNodeResponse(rpclink, response, usedEncryptedKey)
}

async function main() {
  const contractAddress = deployedAddress
  const [signer] = await ethers.getSigners()

  const contractFactory = await ethers.getContractFactory('PERC20Sample')
  const contract = contractFactory.attach(contractAddress)

  const functionName = 'balanceOf'
  const functionArgs = [signer.address]
  try {
    const responseMessage = await sendShieldedQuery(
      signer,
      contractAddress,
      contract.interface.encodeFunctionData(functionName, functionArgs)
    )
    const totalBalance = contract.interface.decodeFunctionResult(functionName, responseMessage)[0]
    console.log('Total Balance is:', ethers.formatUnits(totalBalance, 18), 'Token')
  } catch (error) {
    console.error('Error fetching balance:', error)
  }
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
EOL
echo "balance-of.ts script created."

# Create transfer.ts script
echo "Creating transfer.ts script..."
cat << 'EOL' > scripts/transfer.ts
import { ethers, network } from 'hardhat'
import { encryptDataField } from '@swisstronik/utils'
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/src/signers'
import { HttpNetworkConfig } from 'hardhat/types'
import * as fs from 'fs'
import * as path from 'path'
import deployedAddress from '../utils/deployed-address'

const sendShieldedTransaction = async (
  signer: HardhatEthersSigner,
  destination: string,
  data: string,
  value: number
) => {
  const rpclink = (network.config as HttpNetworkConfig).url

  const [encryptedData] = await encryptDataField(rpclink, data)

  return await signer.sendTransaction({
    from: signer.address,
    to: destination,
    data: encryptedData,
    value,
  })
}

async function main() {
  const contractAddress = deployedAddress

  const [signer] = await ethers.getSigners()

  const contractFactory = await ethers.getContractFactory('PERC20Sample')
  const contract = contractFactory.attach(contractAddress)

  const functionName = 'transfer'
  const receiptAddress = '0x16af037878a6cAce2Ea29d39A3757aC2F6F7aac1' // This is swisstronik dev address, don't modify
  const amount = 1 * 10 ** 18
  const functionArgs = [receiptAddress, `${amount}`]
  const setMessageTx = await sendShieldedTransaction(
    signer,
    contractAddress,
    contract.interface.encodeFunctionData(functionName, functionArgs),
    0
  )
  await setMessageTx.wait()

  console.log('Transaction Receipt: ', setMessageTx.hash)
  const filePath = path.join(__dirname, '../utils/tx-hash.txt')
  fs.writeFileSync(filePath, `Tx hash : https://explorer-evm.testnet.swisstronik.com/tx/${setMessageTx.hash}\n`, {
    flag: 'a',
  })
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
EOL
echo "transfer.ts script created."

# Deploy the contract
echo "Deploying the contract..."
npx hardhat run scripts/deploy.ts --network swisstronik
echo "Contract deployed."

# Mint the tokens
echo "Minting tokens..."
npx hardhat run scripts/mint.ts --network swisstronik
echo "Tokens minted."

# Check balance of tokens
echo "Checking token balance..."
npx hardhat run scripts/balance-of.ts --network swisstronik
echo "Balance checked."

# Transfer tokens (optional, based on user requirement)
echo "Transferring tokens..."
npx hardhat run scripts/transfer.ts --network swisstronik
echo "Tokens transferred."

echo "All operations completed successfully."
