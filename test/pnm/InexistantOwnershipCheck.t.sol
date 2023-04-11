// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/registry/ENSRegistry.sol";
import {MaliciousRegistrar} from "./MaliciousRegistrar.sol";
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

contract InexistantOwnershipCheck is PTest {
    NameWrapper public wrapper;
    ENSRegistry public registry;
    StaticMetadataService public metadata;
    IETHRegistrarController public controller;
    MaliciousRegistrar public baseRegistrar;
    ReverseRegistrar public reverseRegistrar;
    PublicResolver public publicResolver;

    address owner;
    address bob;
    address agent;

    address MOCK_RESOLVER = 0x4976fb03C32e5B8cfe2b6cCB31c09Ba78EBaBa41;
    address EMPTY_ADDRESS = 0x0000000000000000000000000000000000000000;
    bytes32 ROOT_NODE =
        0x0000000000000000000000000000000000000000000000000000000000000000;
    uint256 CONTRACT_INIT_TIMESTAMP = 90 days;

    bytes32 node1;
    bytes32 node2;

    address savedResolver;
    uint64 savedTTL;

    struct LogInfo {
        string label;
        bool isWrapped;
        address ensOwner;
    }

    LogInfo[] pnmLogs;

    function setUp() public {
        owner = makeAddr("OWNER");
        bob = makeAddr("BOB");
        agent = getAgent();

        vm.deal(owner, 1 ether);

        vm.startPrank(owner);

        // warp beyond expire + grace period
        vm.warp(CONTRACT_INIT_TIMESTAMP + 1);

        // registry
        registry = new ENSRegistry();

        // base registrar
        baseRegistrar = new MaliciousRegistrar(
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
        wrapper.setController(agent, true);

        baseRegistrar.setApprovalForAll(address(wrapper), true);

        vm.stopPrank();
    }

    function actionRegisterAndWrap(string memory label) public {
        vm.startPrank(agent);

        wrapper.registerAndWrapETH2LD(
            label,
            bob,
            10 days,
            EMPTY_ADDRESS,
            0
        );

        string memory fullname = string.concat(label, ".eth");
        bytes32 node = namehash(fullname);
        uint256 nodeid = uint256(node);

        bool isWrapped = false;
        if (wrapper.ownerOf(nodeid) == bob) {
            isWrapped = true;
        }

        address ensOwner = registry.owner(node);

        pnmLogs.push(LogInfo(
            label,
            isWrapped,
            ensOwner
        ));

        vm.stopPrank();
    }
    
    function invariantIsOwnerOfWrappedName() public {
        for (uint i = 0; i < pnmLogs.length; ++i) {
            LogInfo memory log = pnmLogs[i];
            if (log.isWrapped) {
                require(log.ensOwner == address(wrapper),
                    "user owns the wrapped name but wrapper doesn't own the ENS record"
                );
            }
        }

        delete pnmLogs;
    }

    function testOwnershipERC1155() public {
        vm.startPrank(agent);

        wrapper.registerAndWrapETH2LD(
            "sub1",
            bob,
            10 days,
            EMPTY_ADDRESS,
            0
        );

        // 1. The ERC1155 is owned by bob
        // 2. Then, the registry must show that the record is owned by the wrapper 
        require(wrapper.ownerOf(uint256(namehash("sub1.eth"))) == bob 
            && registry.owner(namehash("sub1.eth")) == address(wrapper),
            "user owns the wrapped name but wrapper doesn't own the ENS record");

        vm.stopPrank();
    }

    // utility methods

    function namehash(string memory name) private pure returns (bytes32) {
        (, bytes32 testnameNamehash) = NameEncoder.dnsEncodeName(name);
        return testnameNamehash;
    }

    function labelhash(string memory label) private pure returns (bytes32) {
        return keccak256(bytes(label));
    }
}
