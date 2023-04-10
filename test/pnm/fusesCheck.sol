// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/registry/ENSRegistry.sol";
import "../../contracts/ethregistrar/BaseRegistrarImplementation.sol";
import "../../contracts/ethregistrar/DummyOracle.sol";
import "../../contracts/wrapper/StaticMetadataService.sol";
import "../../contracts/wrapper/IMetadataService.sol";
import "../../contracts/wrapper/NameWrapper.sol";

import {IncompatibleParent, IncorrectTargetOwner, OperationProhibited, Unauthorised} from "../../contracts/wrapper/NameWrapper.sol";
import {CANNOT_UNWRAP, CANNOT_BURN_FUSES, CANNOT_TRANSFER, CANNOT_SET_RESOLVER, CANNOT_SET_TTL, CANNOT_CREATE_SUBDOMAIN, PARENT_CANNOT_CONTROL, CAN_DO_EVERYTHING} from "../../contracts/wrapper/INameWrapper.sol";
import {NameEncoder} from "../../contracts/utils/NameEncoder.sol";
import {ReverseRegistrar} from "../../contracts/reverseRegistrar/ReverseRegistrar.sol";
import {PublicResolver} from "../../contracts/resolvers/PublicResolver.sol";
import {AggregatorInterface, StablePriceOracle} from "../../contracts/ethregistrar/StablePriceOracle.sol";
import {ETHRegistrarController, IETHRegistrarController, IPriceOracle} from "../../contracts/ethregistrar/ETHRegistrarController.sol";

import {PTest} from "lib/narya-contracts/PTest.sol";
import {VmSafe} from "lib/narya-contracts/lib/forge-std/src/Vm.sol";
import {console} from "lib/narya-contracts/lib/forge-std/src/console.sol";

contract wrongEmittedEvent is PTest {
    NameWrapper public wrapper;
    ENSRegistry public registry;
    StaticMetadataService public metadata;
    IETHRegistrarController public controller;
    BaseRegistrarImplementation public baseRegistrar;
    ReverseRegistrar public reverseRegistrar;
    PublicResolver public publicResolver;

    address owner;
    address agent;

    address MOCK_RESOLVER = 0x4976fb03C32e5B8cfe2b6cCB31c09Ba78EBaBa41;
    address EMPTY_ADDRESS = 0x0000000000000000000000000000000000000000;
    bytes32 ROOT_NODE =
        0x0000000000000000000000000000000000000000000000000000000000000000;
    uint256 CONTRACT_INIT_TIMESTAMP = 90 days;

    bytes32 node1;
    bytes32 node2;

    function setUp() public {
        owner = makeAddr("OWNER");
        agent = getAgent();

        vm.deal(owner, 1 ether);

        vm.startPrank(owner);

        // warp beyond expire + grace period
        vm.warp(CONTRACT_INIT_TIMESTAMP + 1);

        // registry
        registry = new ENSRegistry();

        // base registrar
        baseRegistrar = new BaseRegistrarImplementation(
            registry,
            namehash("eth")
        );

        baseRegistrar.addController(owner);

        // metadata
        metadata = new StaticMetadataService("https://ens.domains");
        IMetadataService ms = IMetadataService(address(metadata));

        // reverse registrar
        reverseRegistrar = new ReverseRegistrar(registry);

        registry.setSubnodeOwner(ROOT_NODE, labelhash("reverse"), owner);
        registry.setSubnodeOwner(
            namehash("reverse"),
            labelhash("addr"),
            address(reverseRegistrar)
        );

        publicResolver = new PublicResolver(
            registry,
            INameWrapper(address(0)),
            address(0),
            address(reverseRegistrar)
        );

        reverseRegistrar.setDefaultResolver(address(publicResolver));

        // name wrapper
        wrapper = new NameWrapper(registry, baseRegistrar, ms);

        node1 = registry.setSubnodeOwner(
            ROOT_NODE,
            labelhash("eth"),
            address(baseRegistrar)
        );
        node2 = registry.setSubnodeOwner(ROOT_NODE, labelhash("xyz"), agent);

        baseRegistrar.addController(address(wrapper));
        baseRegistrar.addController(owner);
        wrapper.setController(owner, true);

        baseRegistrar.setApprovalForAll(address(wrapper), true);

        // setup oracles
        DummyOracle dummyOracle = new DummyOracle(100000000);
        AggregatorInterface aggregator = AggregatorInterface(
            address(dummyOracle)
        );

        uint256[] memory rentPrices = new uint256[](5);
        uint8[5] memory _prices = [0, 0, 4, 2, 1];
        for (uint256 i = 0; i < _prices.length; i++) {
            rentPrices[i] = _prices[i];
        }

        StablePriceOracle priceOracle = new StablePriceOracle(
            aggregator,
            rentPrices
        );

        ETHRegistrarController ensReg = new ETHRegistrarController(
            baseRegistrar,
            priceOracle,
            0, // min commitment age
            86400, // max commitment age
            reverseRegistrar,
            wrapper,
            registry
        );

        controller = IETHRegistrarController(ensReg);

        wrapper.setController(address(controller), true);

        wrapper.registerAndWrapETH2LD(
            "sub1",
            agent,
            10 days,
            EMPTY_ADDRESS,
            uint16(CANNOT_UNWRAP)
        );

        wrapper.registerAndWrapETH2LD(
            "sub2",
            agent,
            10 days,
            EMPTY_ADDRESS,
            uint16(CANNOT_UNWRAP) // CANNOT_CREATE_SUBDOMAIN
        );

        vm.stopPrank();
    }

    function invariantCannotUnwrap() public {
        vm.startPrank(agent);

        vm.expectRevert();
        wrapper.unwrapETH2LD(labelhash("sub1"), agent, agent);

        vm.stopPrank();
    }

    function testme() public {
        vm.startPrank(agent);

        // vm.expectRevert();
        wrapper.setSubnodeOwner(
            namehash("sub22.sub2.eth"),
            "sub2",
            agent,
            0,
            0
        );

        vm.stopPrank();
    }

    function invariantOwnerCheck() public {}

    // utility methods

    function namehash(string memory name) private pure returns (bytes32) {
        (, bytes32 testnameNamehash) = NameEncoder.dnsEncodeName(name);
        return testnameNamehash;
    }

    function labelhash(string memory label) private pure returns (bytes32) {
        return keccak256(bytes(label));
    }
}
