import chai, { expect } from 'chai'
import { Contract } from 'ethers'
import { solidity, MockProvider, createFixtureLoader } from 'ethereum-waffle'
import { BigNumber, bigNumberify, defaultAbiCoder } from 'ethers/utils'

import { expandTo18Decimals, mineBlock, encodePrice } from './shared/utilities'
import { pairFixture } from './shared/fixtures'
import { AddressZero } from 'ethers/constants'

chai.use(solidity)

const overrides = {
  gasLimit: 9999999
}

const Rules = [
    {ABI: "setVotingDuration(uint256)", types: ["uint256"]},
    {ABI: "setMinimalLevel(uint256)", types: ["uint256"]},
    {ABI: "setDumpProtectionVars(uint256,uint256)", types: ["uint256","uint256"]}
]

describe('BSwapVoting', () => {
  const provider = new MockProvider({
    hardfork: 'istanbul',
    mnemonic: 'horn horn horn horn horn horn horn horn horn horn horn horn',
    gasLimit: 9999999
  })
  const [wallet, other] = provider.getWallets()
  const loadFixture = createFixtureLoader(provider, [wallet])

  let factory: Contract
  let token0: Contract
  let token1: Contract
  let pair: Contract
  beforeEach(async () => {
    const fixture = await loadFixture(pairFixture)
    factory = fixture.factory
    token0 = fixture.token0
    token1 = fixture.token1
    pair = fixture.pair
  })
  async function addLiquidity(token0Amount: BigNumber, token1Amount: BigNumber) {
    await token0.transfer(pair.address, token0Amount)
    await token1.transfer(pair.address, token1Amount)
    await pair.mint(wallet.address, overrides)
  }
/*
    // funcAbi - string, args - array of arguments
    // returns hex string (bytes) ABI encoded arguments
    function encodeArgs(funcAbi, args) {
        var types = parseTypes(funcAbi);
        return web3.eth.abi.encodeParameters(types,args);
    }

    function parseTypes(funcAbi) {
        var ar = funcAbi.split(/\w*\(|,|\)/)
        ar.shift();
        ar.pop();
        return ar;
    }
  async function update_option(ruleId, val) {
    var args = encodeArgs(Rules[ruleId].ABI, val)

  }
*/
  it('voting', async () => {
    const token0Amount = expandTo18Decimals(10)
    const token1Amount = expandTo18Decimals(10)
    await addLiquidity(token0Amount, token1Amount)
    //const blockTimestamp = (await pair.getReserves())[2]
    await expect(pair.createBallot(0, defaultAbiCoder.encode(Rules[0].types,[601])))
        .to.emit(pair, 'BallotCreated')
        .withArgs(0, 1)    
        .to.emit(pair, 'ApplyBallot')
        .withArgs(0, 1)    
    //await mineBlock(provider, blockTimestamp + 20)
    expect(await pair.votingTime()).to.eq(601)
/*
    const swapAmount = expandTo18Decimals(1)
    const expectedOutputAmount = bigNumberify('1562497915624478906')
    await token0.transfer(pair.address, swapAmount)
    await expect(pair.swap(0, expectedOutputAmount, wallet.address, '0x', overrides))
      .to.emit(token1, 'Transfer')
      .withArgs(pair.address, wallet.address, expectedOutputAmount)
      .to.emit(pair, 'Sync')
      .withArgs(token0Amount.add(swapAmount), token1Amount.sub(expectedOutputAmount))
      .to.emit(pair, 'Swap')
      .withArgs(wallet.address, swapAmount, 0, 0, expectedOutputAmount, wallet.address)

    const reserves = await pair.getReserves()
    expect(reserves[0]).to.eq(token0Amount.add(swapAmount))
    expect(reserves[1]).to.eq(token1Amount.sub(expectedOutputAmount))
    expect(await token0.balanceOf(pair.address)).to.eq(token0Amount.add(swapAmount))
    expect(await token1.balanceOf(pair.address)).to.eq(token1Amount.sub(expectedOutputAmount))
    const totalSupplyToken0 = await token0.totalSupply()
    const totalSupplyToken1 = await token1.totalSupply()
    expect(await token0.balanceOf(wallet.address)).to.eq(totalSupplyToken0.sub(token0Amount).sub(swapAmount))
    expect(await token1.balanceOf(wallet.address)).to.eq(totalSupplyToken1.sub(token1Amount).add(expectedOutputAmount))
    */
  })
})
