// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// OpenZeppelin
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// Chainlink
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
// import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
// import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract TickItOn is
    ERC721,
    ERC721URIStorage,
    CCIPReceiver,
    VRFConsumerBaseV2,
    KeeperCompatibleInterface,
    Ownable,
    ReentrancyGuard
{
    // ============ STATE VARIABLES ============

    // Chainlink interfaces
    IRouterClient private immutable ccipRouter;
    VRFCoordinatorV2Interface private immutable vrfCoordinator;
    AggregatorV3Interface private immutable nativePriceFeed;
    IERC20 private immutable linkToken;

    // VRF Configuration
    uint64 private immutable vrfSubscriptionId;
    bytes32 private immutable vrfKeyHash;
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 100000;
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 3;
    uint32 private constant VRF_NUM_WORDS = 1;

    // Platform Configuration
    uint256 private constant PLATFORM_FEE = 200; // 2%
    uint256 private constant RESALE_PLATFORM_SHARE = 70; // 70%
    uint256 private constant RESALE_ORGANIZER_SHARE = 30; // 30%
    uint256 private constant PRICE_INCREMENT_BASIS_POINTS = 10; // 0.1%
    uint256 private constant BASIS_POINTS = 10000;

    // Chain IDs for CCIP
    mapping(string => uint64) public chainSelectors;
    mapping(uint64 => bool) public allowedChains;

    // Counters
    uint256 private eventCounter;
    uint256 private ticketCounter;
    uint256 private resaleCounter;

    // ============ STRUCTS ============

    struct Event {
        uint256 eventId;
        address organizer;
        string name;
        string description;
        string venue;
        uint256 eventDate;
        uint256 totalTickets;
        uint256 basePrice; // In native token (wei)
        uint256 ticketsSold;
        uint256 organizerStake;
        uint64 hostChain; // Chain where event is hosted
        bool isActive;
        bool isCompleted;
        string metadataURI;
    }

    struct Ticket {
        uint256 ticketId;
        uint256 eventId;
        address owner;
        uint256 purchasePrice;
        uint256 purchaseTimestamp;
        uint64 purchaseChain;
        bool isResale;
        bool isUsed;
    }

    struct ResaleListing {
        uint256 resaleId;
        uint256 ticketId;
        address seller;
        uint256 originalPrice;
        uint256 currentMarketPrice;
        bool isActive;
        uint256 listedTimestamp;
    }

    struct CrossChainMessage {
        address buyer;
        uint256 eventId;
        uint256 ticketQuantity;
        uint256 totalPayment;
        uint64 sourceChain;
        MessageType msgType;
    }

    enum MessageType {
        BUY_TICKET,
        RESALE_TICKET
    }

    // ============ MAPPINGS ============

    mapping(uint256 => Event) public events;
    mapping(uint256 => Ticket) public tickets;
    mapping(uint256 => ResaleListing) public resaleListings;
    mapping(address => uint256[]) public userTickets;
    mapping(address => uint256[]) public organizerEvents;
    mapping(uint256 => uint256[]) public eventTickets;
    mapping(uint256 => uint256) public vrfRequestToEventId; // Changed from address to uint256
    mapping(uint256 => uint256) public ticketToResale;

    // ============ EVENTS ============

    event EventCreated(
        uint256 indexed eventId,
        address indexed organizer,
        string name,
        uint256 basePrice,
        uint256 totalTickets,
        uint64 hostChain
    );

    event TicketPurchased(
        uint256 indexed ticketId,
        uint256 indexed eventId,
        address indexed buyer,
        uint256 price,
        uint64 purchaseChain,
        bool isCrossChain
    );

    event TicketResaleListed(
        uint256 indexed resaleId,
        uint256 indexed ticketId,
        address indexed seller,
        uint256 marketPrice
    );

    event TicketResold(
        uint256 indexed resaleId,
        uint256 indexed ticketId,
        address indexed seller,
        address buyer, // Removed indexed - only 3 indexed parameters allowed
        uint256 salePrice
    );

    event CrossChainPurchaseReceived(
        uint256 indexed eventId,
        address indexed buyer,
        uint64 sourceChain,
        uint256 payment
    );

    event VRFRewardTriggered(
        uint256 indexed eventId,
        address indexed winner,
        uint256 rewardAmount
    );

    // ============ CONSTRUCTOR ============

    constructor(
        address _ccipRouter,
        address _vrfCoordinator,
        address _nativePriceFeed,
        address _linkToken,
        uint64 _vrfSubscriptionId,
        bytes32 _vrfKeyHash,
        string memory _chainName,
        uint64 _chainSelector
    )
        ERC721("TickItOn", "TICK")
        CCIPReceiver(_ccipRouter)
        VRFConsumerBaseV2(_vrfCoordinator)
        Ownable(msg.sender) // Fixed: Ownable constructor needs initial owner
    {
        ccipRouter = IRouterClient(_ccipRouter);
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        nativePriceFeed = AggregatorV3Interface(_nativePriceFeed);
        linkToken = IERC20(_linkToken);
        vrfSubscriptionId = _vrfSubscriptionId;
        vrfKeyHash = _vrfKeyHash;

        // Set up chain configuration
        chainSelectors[_chainName] = _chainSelector;
        allowedChains[_chainSelector] = true;
    }

    // ============ ORGANIZER FUNCTIONS ============

    /**
     * @dev Create a new event with staking requirement
     * @param _name Event name
     * @param _description Event description
     * @param _venue Event venue
     * @param _eventDate Event date (timestamp)
     * @param _totalTickets Total tickets available
     * @param _basePrice Base price in native token (wei)
     * @param _metadataURI IPFS URI for event metadata
     */
    function createEvent(
        string memory _name,
        string memory _description,
        string memory _venue,
        uint256 _eventDate,
        uint256 _totalTickets,
        uint256 _basePrice,
        string memory _metadataURI
    ) external payable nonReentrant {
        require(_eventDate > block.timestamp, "Event date must be in future");
        require(_totalTickets > 0, "Must have at least 1 ticket");
        require(_basePrice > 0, "Base price must be greater than 0");

        // Calculate required stake (10% of total potential revenue)
        uint256 maxPrice = calculateDynamicPrice(_basePrice, _totalTickets);
        uint256 requiredStake = (maxPrice * _totalTickets * 10) / 100;
        require(msg.value >= requiredStake, "Insufficient stake amount");

        eventCounter++;
        uint64 currentChain = getCurrentChainSelector();

        events[eventCounter] = Event({
            eventId: eventCounter,
            organizer: msg.sender,
            name: _name,
            description: _description,
            venue: _venue,
            eventDate: _eventDate,
            totalTickets: _totalTickets,
            basePrice: _basePrice,
            ticketsSold: 0,
            organizerStake: msg.value,
            hostChain: currentChain,
            isActive: true,
            isCompleted: false,
            metadataURI: _metadataURI
        });

        organizerEvents[msg.sender].push(eventCounter);

        emit EventCreated(
            eventCounter,
            msg.sender,
            _name,
            _basePrice,
            _totalTickets,
            currentChain
        );
    }

    // ============ TICKET PURCHASE FUNCTIONS ============

    /**
     * @dev Buy ticket on same chain as event
     * @param _eventId Event ID to buy ticket for
     * @param _quantity Number of tickets to buy
     */
    function buyTicket(
        uint256 _eventId,
        uint256 _quantity
    ) external payable nonReentrant {
        Event storage eve = events[_eventId];
        require(eve.isActive, "Event not active");
        require(
            eve.ticketsSold + _quantity <= eve.totalTickets,
            "Not enough tickets"
        );
        require(block.timestamp < eve.eventDate, "Event has ended");

        uint256 totalCost = 0;
        for (uint256 i = 0; i < _quantity; i++) {
            totalCost += calculateDynamicPrice(
                eve.basePrice,
                eve.ticketsSold + i
            );
        }

        require(msg.value >= totalCost, "Insufficient payment");

        // Mint tickets
        for (uint256 i = 0; i < _quantity; i++) {
            _mintTicket(
                _eventId,
                msg.sender,
                calculateDynamicPrice(eve.basePrice, eve.ticketsSold),
                false
            );
            eve.ticketsSold++;
        }

        // Refund excess payment
        if (msg.value > totalCost) {
            payable(msg.sender).transfer(msg.value - totalCost);
        }

        // Check for VRF reward trigger (every 100th ticket)
        if (eve.ticketsSold % 100 == 0) {
            _triggerVRFReward(_eventId);
        }
    }

    /**
     * @dev Buy ticket cross-chain via CCIP
     * @param _eventId Event ID on destination chain
     * @param _quantity Number of tickets
     * @param _destinationChain Target chain selector
     * @param _destinationContract Target contract address
     */
    function buyTicketCrossChain(
        uint256 _eventId,
        uint256 _quantity,
        uint64 _destinationChain,
        address _destinationContract
    ) external payable nonReentrant {
        require(allowedChains[_destinationChain], "Chain not supported");
        require(msg.value > 0, "Must send payment");

        // Calculate CCIP fee
        uint256 ccipFee = _calculateCCIPFee(_destinationChain, msg.value);
        require(
            linkToken.balanceOf(msg.sender) >= ccipFee,
            "Insufficient LINK for CCIP fee"
        );
        require(
            linkToken.allowance(msg.sender, address(this)) >= ccipFee,
            "LINK allowance needed"
        );

        // Transfer LINK fee from user
        linkToken.transferFrom(msg.sender, address(this), ccipFee);

        // Prepare CCIP message
        CrossChainMessage memory message = CrossChainMessage({
            buyer: msg.sender,
            eventId: _eventId,
            ticketQuantity: _quantity,
            totalPayment: msg.value,
            sourceChain: getCurrentChainSelector(),
            msgType: MessageType.BUY_TICKET
        });

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_destinationContract),
            data: abi.encode(message),
            tokenAmounts: new Client.EVMTokenAmount[](1),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 300000})
            ),
            feeToken: address(linkToken)
        });

        // Include native token transfer
        ccipMessage.tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(0), // Native token
            amount: msg.value
        });

        // Send CCIP message
        ccipRouter.ccipSend(_destinationChain, ccipMessage);
    }

    /**
     * @dev Handle incoming CCIP messages
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        CrossChainMessage memory crossChainMsg = abi.decode(
            message.data,
            (CrossChainMessage)
        );

        if (crossChainMsg.msgType == MessageType.BUY_TICKET) {
            _processCrossChainPurchase(
                crossChainMsg,
                message.destTokenAmounts[0].amount
            );
        } else if (crossChainMsg.msgType == MessageType.RESALE_TICKET) {
            _processCrossChainResale(
                crossChainMsg,
                message.destTokenAmounts[0].amount
            );
        }
    }

    function _processCrossChainPurchase(
        CrossChainMessage memory message,
        uint256 receivedAmount
    ) internal {
        Event storage eve = events[message.eventId];
        require(eve.isActive, "Event not active");
        require(
            eve.ticketsSold + message.ticketQuantity <= eve.totalTickets,
            "Not enough tickets"
        );

        uint256 totalCost = 0;
        for (uint256 i = 0; i < message.ticketQuantity; i++) {
            totalCost += calculateDynamicPrice(
                eve.basePrice,
                eve.ticketsSold + i
            );
        }

        require(
            receivedAmount >= totalCost,
            "Insufficient cross-chain payment"
        );

        // Mint tickets to buyer
        for (uint256 i = 0; i < message.ticketQuantity; i++) {
            _mintTicket(
                message.eventId,
                message.buyer,
                calculateDynamicPrice(eve.basePrice, eve.ticketsSold),
                true
            );
            eve.ticketsSold++;
        }

        emit CrossChainPurchaseReceived(
            message.eventId,
            message.buyer,
            message.sourceChain,
            receivedAmount
        );

        // Check for VRF reward
        if (eve.ticketsSold % 100 == 0) {
            _triggerVRFReward(message.eventId);
        }
    }

    // ============ RESALE FUNCTIONS ============

    /**
     * @dev List ticket for resale
     * @param _ticketId Ticket ID to resale
     */
    function listTicketForResale(uint256 _ticketId) external nonReentrant {
        require(ownerOf(_ticketId) == msg.sender, "Not ticket owner");
        require(!tickets[_ticketId].isUsed, "Ticket already used");
        require(ticketToResale[_ticketId] == 0, "Already listed for resale");

        Ticket storage ticket = tickets[_ticketId];
        Event storage eve = events[ticket.eventId];
        require(block.timestamp < eve.eventDate, "Event has ended");

        // Calculate current market price based on dynamic pricing
        uint256 currentMarketPrice = calculateDynamicPrice(
            eve.basePrice,
            eve.ticketsSold
        );

        resaleCounter++;
        resaleListings[resaleCounter] = ResaleListing({
            resaleId: resaleCounter,
            ticketId: _ticketId,
            seller: msg.sender,
            originalPrice: ticket.purchasePrice,
            currentMarketPrice: currentMarketPrice,
            isActive: true,
            listedTimestamp: block.timestamp
        });

        ticketToResale[_ticketId] = resaleCounter;

        emit TicketResaleListed(
            resaleCounter,
            _ticketId,
            msg.sender,
            currentMarketPrice
        );
    }

    /**
     * @dev Buy resale ticket on same chain
     * @param _resaleId Resale listing ID
     */
    function buyResaleTicket(uint256 _resaleId) external payable nonReentrant {
        ResaleListing storage resale = resaleListings[_resaleId];
        require(resale.isActive, "Resale not active");
        require(msg.value >= resale.currentMarketPrice, "Insufficient payment");

        _executeResale(_resaleId, msg.sender, msg.value);
    }

    /**
     * @dev Buy resale ticket cross-chain
     * @param _resaleId Resale ID on destination chain
     * @param _destinationChain Target chain
     * @param _destinationContract Target contract
     */
    function buyResaleTicketCrossChain(
        uint256 _resaleId,
        uint64 _destinationChain,
        address _destinationContract
    ) external payable nonReentrant {
        require(allowedChains[_destinationChain], "Chain not supported");

        uint256 ccipFee = _calculateCCIPFee(_destinationChain, msg.value);
        require(
            linkToken.balanceOf(msg.sender) >= ccipFee,
            "Insufficient LINK"
        );
        require(
            linkToken.allowance(msg.sender, address(this)) >= ccipFee,
            "LINK allowance needed"
        );

        linkToken.transferFrom(msg.sender, address(this), ccipFee);

        CrossChainMessage memory message = CrossChainMessage({
            buyer: msg.sender,
            eventId: _resaleId, // Using eventId field for resaleId
            ticketQuantity: 1,
            totalPayment: msg.value,
            sourceChain: getCurrentChainSelector(),
            msgType: MessageType.RESALE_TICKET
        });

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_destinationContract),
            data: abi.encode(message),
            tokenAmounts: new Client.EVMTokenAmount[](1),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 300000})
            ),
            feeToken: address(linkToken)
        });

        ccipMessage.tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(0),
            amount: msg.value
        });

        ccipRouter.ccipSend(_destinationChain, ccipMessage);
    }

    function _processCrossChainResale(
        CrossChainMessage memory message,
        uint256 receivedAmount
    ) internal {
        uint256 resaleId = message.eventId; // eventId field used for resaleId
        _executeResale(resaleId, message.buyer, receivedAmount);
    }

    function _executeResale(
        uint256 _resaleId,
        address _buyer,
        uint256 _payment
    ) internal {
        ResaleListing storage resale = resaleListings[_resaleId];
        Ticket storage ticket = tickets[resale.ticketId];
        Event storage eve = events[ticket.eventId];

        require(_payment >= resale.currentMarketPrice, "Insufficient payment");

        // Calculate payments according to resale rules
        uint256 sellerReceives = (resale.originalPrice * 90) / 100; // 90% of original price
        uint256 remaining = _payment - sellerReceives;
        uint256 platformFee = (remaining * RESALE_PLATFORM_SHARE) / 100;
        uint256 organizerFee = (remaining * RESALE_ORGANIZER_SHARE) / 100;

        // Transfer payments
        payable(resale.seller).transfer(sellerReceives);
        payable(owner()).transfer(platformFee);
        payable(eve.organizer).transfer(organizerFee);

        // Transfer ticket ownership
        _transfer(resale.seller, _buyer, resale.ticketId);
        ticket.owner = _buyer;
        ticket.isResale = true;

        // Update arrays
        _removeFromArray(userTickets[resale.seller], resale.ticketId);
        userTickets[_buyer].push(resale.ticketId);

        // Deactivate resale
        resale.isActive = false;
        ticketToResale[resale.ticketId] = 0;

        // Refund excess
        if (_payment > resale.currentMarketPrice) {
            payable(_buyer).transfer(_payment - resale.currentMarketPrice);
        }

        emit TicketResold(
            _resaleId,
            resale.ticketId,
            resale.seller,
            _buyer,
            _payment
        );
    }

    // ============ VRF FUNCTIONS ============

    function _triggerVRFReward(uint256 _eventId) internal {
        uint256 requestId = vrfCoordinator.requestRandomWords(
            vrfKeyHash,
            vrfSubscriptionId,
            VRF_REQUEST_CONFIRMATIONS,
            VRF_CALLBACK_GAS_LIMIT,
            VRF_NUM_WORDS
        );

        vrfRequestToEventId[requestId] = _eventId;
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        uint256 eventId = vrfRequestToEventId[requestId];
        Event storage eve = events[eventId];

        if (eve.ticketsSold > 0) {
            // Select random ticket holder
            uint256 randomIndex = randomWords[0] % eve.ticketsSold;
            uint256 winningTicketId = eventTickets[eventId][randomIndex];
            address winner = ownerOf(winningTicketId);

            // Calculate reward (5% of current ticket price)
            uint256 currentPrice = calculateDynamicPrice(
                eve.basePrice,
                eve.ticketsSold
            );
            uint256 reward = (currentPrice * 5) / 100;

            if (address(this).balance >= reward) {
                payable(winner).transfer(reward);
                emit VRFRewardTriggered(eventId, winner, reward);
            }
        }
    }

    // ============ AUTOMATION FUNCTIONS ============

    function checkUpkeep(
        bytes calldata
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256[] memory expiredEvents = new uint256[](100);
        uint256 count = 0;

        for (uint256 i = 1; i <= eventCounter && count < 100; i++) {
            if (
                events[i].isActive &&
                !events[i].isCompleted &&
                block.timestamp > events[i].eventDate + 1 days
            ) {
                expiredEvents[count] = i;
                count++;
            }
        }

        upkeepNeeded = count > 0;
        performData = abi.encode(expiredEvents, count);
    }

    function performUpkeep(bytes calldata performData) external override {
        (uint256[] memory expiredEvents, uint256 count) = abi.decode(
            performData,
            (uint256[], uint256)
        );

        for (uint256 i = 0; i < count; i++) {
            _completeEvent(expiredEvents[i]);
        }
    }

    function _completeEvent(uint256 _eventId) internal {
        Event storage eve = events[_eventId];
        require(block.timestamp > eve.eventDate + 1 days, "Event not expired");

        eve.isCompleted = true;
        eve.isActive = false;

        // Return stake to organizer minus platform fee
        uint256 platformFee = (eve.organizerStake * PLATFORM_FEE) /
            BASIS_POINTS;
        uint256 returnAmount = eve.organizerStake - platformFee;

        payable(eve.organizer).transfer(returnAmount);
        payable(owner()).transfer(platformFee);
    }

    // ============ HELPER FUNCTIONS ============

    function _mintTicket(
        uint256 _eventId,
        address _to,
        uint256 _price,
        bool _isCrossChain
    ) internal {
        ticketCounter++;

        tickets[ticketCounter] = Ticket({
            ticketId: ticketCounter,
            eventId: _eventId,
            owner: _to,
            purchasePrice: _price,
            purchaseTimestamp: block.timestamp,
            purchaseChain: getCurrentChainSelector(),
            isResale: false,
            isUsed: false
        });

        userTickets[_to].push(ticketCounter);
        eventTickets[_eventId].push(ticketCounter);

        _mint(_to, ticketCounter);

        // Set token URI with event metadata
        string memory tokenURI = string(
            abi.encodePacked(
                events[_eventId].metadataURI,
                "/",
                Strings.toString(ticketCounter)
            )
        );
        _setTokenURI(ticketCounter, tokenURI);

        emit TicketPurchased(
            ticketCounter,
            _eventId,
            _to,
            _price,
            getCurrentChainSelector(),
            _isCrossChain
        );
    }

    function calculateDynamicPrice(
        uint256 _basePrice,
        uint256 _ticketsSold
    ) public pure returns (uint256) {
        // Price increases by 0.1% for each ticket sold
        return
            _basePrice +
            ((_basePrice * _ticketsSold * PRICE_INCREMENT_BASIS_POINTS) /
                BASIS_POINTS);
    }

    function _calculateCCIPFee(
        uint64 _destinationChain,
        uint256 _amount
    ) internal view returns (uint256) {
        // Simplified CCIP fee calculation
        // In production, use ccipRouter.getFee()
        return _amount / 100; // 1% of amount as CCIP fee
    }

    function getCurrentChainSelector() public view returns (uint64) {
        if (block.chainid == 1) return 5009297550715157269; // Ethereum
        if (block.chainid == 137) return 4051577828743386545; // Polygon
        if (block.chainid == 43114) return 6433500567565415381; // Avalanche
        revert("Unsupported chain");
    }

    function _removeFromArray(uint256[] storage array, uint256 value) internal {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == value) {
                array[i] = array[array.length - 1];
                array.pop();
                break;
            }
        }
    }

    // ============ VIEW FUNCTIONS ============

    function getEvent(uint256 _eventId) external view returns (Event memory) {
        return events[_eventId];
    }

    function getTicket(
        uint256 _ticketId
    ) external view returns (Ticket memory) {
        return tickets[_ticketId];
    }

    function getUserTickets(
        address _user
    ) external view returns (uint256[] memory) {
        return userTickets[_user];
    }

    function getEventTickets(
        uint256 _eventId
    ) external view returns (uint256[] memory) {
        return eventTickets[_eventId];
    }

    function getResaleListing(
        uint256 _resaleId
    ) external view returns (ResaleListing memory) {
        return resaleListings[_resaleId];
    }

    function getCurrentTicketPrice(
        uint256 _eventId
    ) external view returns (uint256) {
        Event memory eve = events[_eventId];
        return calculateDynamicPrice(eve.basePrice, eve.ticketsSold);
    }

    // ============ ADMIN FUNCTIONS ============

    function addAllowedChain(uint64 _chainSelector) external onlyOwner {
        allowedChains[_chainSelector] = true;
    }

    function removeAllowedChain(uint64 _chainSelector) external onlyOwner {
        allowedChains[_chainSelector] = false;
    }

    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    // ============ OVERRIDES ============

    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

   function supportsInterface(bytes4 interfaceId) public view override(CCIPReceiver, ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // Accept ETH deposits
    receive() external payable {}
}
