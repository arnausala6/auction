// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BlindAuctionFinalV2
 * @notice Subasta sealed-bid (commit–reveal) optimizada y segura.
 */
contract BlindAuctionFinalV2 {
    // ─────────────────────────────────────────────────────────────
    // Parámetros "del programa" (hardcoded)
    // ─────────────────────────────────────────────────────────────
    uint256 public constant MIN_DEPOSIT = 0.001 ether;
    uint256 public constant MAX_DEPOSIT = 10 ether;

    // [B] MODIFICADO: Usamos bloques en lugar de tiempo. (Aprox 12 seg por bloque)
    // 25 bloques son aprox 5 minutos.
    uint256 public constant MIN_COMMIT_BLOCKS  = 5; //test
    uint256 public constant MIN_REVEAL_BLOCKS  = 5;
    uint256 public constant MIN_PAYMENT_BLOCKS = 5;

    uint256 public constant MIN_MAX_BIDDERS = 3;
    uint256 public constant MAX_MAX_BIDDERS = 200;

    uint256 public constant UNREVEALED_PENALTY_BPS = 10000; // 100%
    uint256 public constant ADVANCE_CALLER_BOUNTY_BPS = 500; // 5%

    // [E] MODIFICADO: Bloques para activar el Dead Man's Switch (Aprox 1 semana = 50,400 bloques)
    uint256 public constant EMERGENCY_TIMEOUT_BLOCKS = 50000;

    // ─────────────────────────────────────────────────────────────
    // Config del vendedor
    // ─────────────────────────────────────────────────────────────
    address public immutable owner;

    // [B] MODIFICADO: Tiempos límite basados en block.number
    uint256 public immutable commitDeadlineBlock;
    uint256 public immutable revealDeadlineBlock;

    uint256 public immutable deposit;          
    uint256 public immutable paymentDurationBlocks; 
    uint256 public immutable maxBidders;       
    uint256 public immutable maxFallbacks;     

    // [D] MODIFICADO: Bandera para productos expirables
    bool public immutable isExpirable;

    // ─────────────────────────────────────────────────────────────
    // Estado por bidder
    // ─────────────────────────────────────────────────────────────
    struct Bidder {
        bytes32 commitment;
        uint256 commitBlock;    // [B] MODIFICADO: tie-break por bloque
        uint256 revealedBid;    
        bool hasCommitted;
        bool hasRevealed;       
        bool withdrawn;         
        bool depositLocked;     
        bool defaulted;         
    }

    mapping(address => Bidder) public bidders;
    address[] public bidderList;

    // [A] MODIFICADO: Guardamos todos los revelados para poder recalcular el Top 10 si fallan
    address[] public allRevealedBidders;
    address[] public top10Bidders;

    // ─────────────────────────────────────────────────────────────
    // Estado de subasta
    // ─────────────────────────────────────────────────────────────
    bool public finalized;
    bool public auctionSuccessful;
    bool public auctionDeserted;
    address public authorizedKeeper;

    uint256 public currentWinnerIndex;
    uint256 public paymentDeadlineBlock; // [B] MODIFICADO
    uint256 public fallbackCount;

    uint256 public ownerProceeds;
    mapping(address => uint256) public rewards; 

    // ─────────────────────────────────────────────────────────────
    // Eventos (Omitidos los que no cambian por brevedad)
    // ─────────────────────────────────────────────────────────────
    event Committed(address indexed bidder, bytes32 commitment);
    event Revealed(address indexed bidder, uint256 bid);
    event Finalized(address indexed firstWinner, uint256 bid, uint256 paymentDeadlineBlock);
    event WinnerPaid(address indexed winner, uint256 totalPaid);
    event WinnerAdvanced(address indexed newWinner, uint256 bid, uint256 paymentDeadlineBlock, uint256 fallbackCount);
    event DepositWithdrawn(address indexed bidder, uint256 amount);
    event DepositConfiscated(address indexed bidder, uint256 amount, string reason);
    event RewardAccrued(address indexed caller, uint256 amount);
    event Deserted();
    event EmergencyWithdraw(address indexed bidder, uint256 amount); // [E] Nuevo evento

    // ─────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────
    modifier inCommitPhase() {
        require(block.number < commitDeadlineBlock, "Commit cerrada"); // [B]
        _;
    }

    modifier inRevealPhase() {
        require(block.number >= commitDeadlineBlock, "Reveal no iniciada"); // [B]
        require(block.number < revealDeadlineBlock, "Reveal cerrada"); // [B]
        _;
    }

    modifier afterReveal() {
        require(block.number > revealDeadlineBlock, "Reveal no terminado"); // [B]
        _;
    }

    modifier isFinalized() {
        require(finalized, "No finalizado");
        _;
    }

    // ─────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────
    constructor(
        uint256 _commitBlocks,
        uint256 _revealBlocks,
        uint256 _deposit,
        uint256 _paymentBlocks,
        uint256 _maxBidders,
        uint256 _maxFallbacks,
        bool _isExpirable // [D] MODIFICADO: Nuevo argumento
    ) {
        require(_commitBlocks >= MIN_COMMIT_BLOCKS, "commitBlocks muy corto");
        require(_revealBlocks >= MIN_REVEAL_BLOCKS, "revealBlocks muy corto");
        
        // [D] MODIFICADO: Si caduca, el tiempo de pago puede ser ultra-rápido (ej. 5 bloques = 1 min).
        // Si no caduca, obligamos al mínimo estándar.
        if (_isExpirable) {
            require(_paymentBlocks > 0, "Debe haber tiempo de pago");
        } else {
            require(_paymentBlocks >= MIN_PAYMENT_BLOCKS, "paymentBlocks muy corto");
        }

        require(_deposit >= MIN_DEPOSIT && _deposit <= MAX_DEPOSIT, "Fianza fuera de rango");
        require(_maxBidders >= MIN_MAX_BIDDERS && _maxBidders <= MAX_MAX_BIDDERS, "maxBidders fuera de rango");

        owner = msg.sender;
        isExpirable = _isExpirable;
        deposit = _deposit;
        paymentDurationBlocks = _paymentBlocks;
        maxBidders = _maxBidders;
        maxFallbacks = _maxFallbacks;

        commitDeadlineBlock = block.number + _commitBlocks; // [B]
        revealDeadlineBlock = commitDeadlineBlock + _revealBlocks; // [B]
    }

    function setKeeper(address _keeper) external {
        require(msg.sender == owner, "Solo el owner");
        require(_keeper != address(0), "Direccion invalida");
        authorizedKeeper = _keeper;
    } 

    // ─────────────────────────────────────────────────────────────
    // Commit: [C] Permite modificar la puja sin pagar doble fianza
    // ─────────────────────────────────────────────────────────────
    function commit(bytes32 _commitment) external payable inCommitPhase {
        require(_commitment != bytes32(0), "Commitment invalido");

        Bidder storage b = bidders[msg.sender];
        
        // [C] MODIFICADO: Si ya pujó, permite actualizar el hash sin cobrar de nuevo
        if (b.hasCommitted) {
            require(msg.value == 0, "Fianza ya pagada, no envies mas ETH");
        } else {
            require(bidderList.length < maxBidders, "Subasta llena");
            require(msg.value == deposit, "Debes pagar la fianza exacta");
            bidderList.push(msg.sender);
            b.hasCommitted = true;
        }

        b.commitment = _commitment;
        b.commitBlock = block.number; // [B] Guardamos el bloque exacto del commit

        emit Committed(msg.sender, _commitment);
    }

    // ─────────────────────────────────────────────────────────────
    // Reveal y Top 10 Optimizado (Problema A)
    // ─────────────────────────────────────────────────────────────
    function reveal(uint256 _bidAmount, bytes32 _salt) external inRevealPhase {
        Bidder storage b = bidders[msg.sender];
        require(b.hasCommitted, "No participaste");
        require(!b.hasRevealed, "Ya revelaste");
        require(_bidAmount >= deposit, "Bid < fianza");

        bytes32 expected = keccak256(abi.encode(_bidAmount, _salt, msg.sender, address(this)));
        require(expected == b.commitment, "Reveal invalido");

        b.hasRevealed = true;
        b.revealedBid = _bidAmount;
        b.depositLocked = true; // Bloqueamos la fianza por seguridad hasta el finalize

        allRevealedBidders.push(msg.sender); // Guardamos historial por si el Top 10 falla
        _insertIntoTop10(msg.sender); // [A] Solo gestionamos un array de 10
        
        emit Revealed(msg.sender, _bidAmount);
    }

    // ─────────────────────────────────────────────────────────────
    // Finalize 
    // ─────────────────────────────────────────────────────────────
    function finalize() external afterReveal {
        require(!finalized, "Ya finalizado");
        finalized = true;

        if (top10Bidders.length == 0) {
            auctionDeserted = true;
            _unlockAllDeposits(); // Liberar todo
            emit Deserted();
            return;
        }

        currentWinnerIndex = 0;
        paymentDeadlineBlock = block.number + paymentDurationBlocks;

        address first = top10Bidders[0];
        emit Finalized(first, bidders[first].revealedBid, paymentDeadlineBlock);
    }

    function payWinningBid() external payable isFinalized {
        require(!auctionDeserted, "Subasta desierta");
        require(!auctionSuccessful, "Ya completada");
        require(currentWinnerIndex < top10Bidders.length, "Sin ganador");
        require(block.number <= paymentDeadlineBlock, "Plazo expirado");

        address w = top10Bidders[currentWinnerIndex];
        require(msg.sender == w, "No eres el ganador actual");

        uint256 bidAmount = bidders[w].revealedBid;
        uint256 remaining = bidAmount > deposit ? bidAmount - deposit : 0;
        require(msg.value == remaining, "Cantidad incorrecta");

        ownerProceeds += (deposit + msg.value);
        auctionSuccessful = true;

        _unlockAllDepositsExceptWinner(w);
        bidders[w].withdrawn = true;

        emit WinnerPaid(w, deposit + msg.value);
    }

    // ─────────────────────────────────────────────────────────────
    // Fallback & Top 10 Recalculation [A]
    // ─────────────────────────────────────────────────────────────
    function advanceWinnerIfUnpaid() external isFinalized {
        require(!auctionDeserted && !auctionSuccessful, "Estado invalido");
        require(currentWinnerIndex < top10Bidders.length, "Sin ganador");
        require(block.number > paymentDeadlineBlock, "Plazo aun activo");

        address defaulter = top10Bidders[currentWinnerIndex];
        Bidder storage bd = bidders[defaulter];
        
        // Confisca fianza
        bd.withdrawn = true;
        bd.depositLocked = false;
        bd.defaulted = true;

        // Bot Bounty
        uint256 bounty = (deposit * ADVANCE_CALLER_BOUNTY_BPS) / 10000;
        rewards[msg.sender] += bounty;
        ownerProceeds += (deposit - bounty);

        emit DepositConfiscated(defaulter, deposit, "winner did not pay");

        fallbackCount += 1;
        currentWinnerIndex += 1;

        // [A] MODIFICADO: Si el top 10 se agota, volvemos a calcular el siguiente top 10
        if (currentWinnerIndex >= top10Bidders.length) {
            _recalculateNextTop10();
        }

        if (top10Bidders.length == 0 || (maxFallbacks != 0 && fallbackCount >= maxFallbacks)) {
            auctionDeserted = true;
            _unlockAllDepositsExceptWinner(address(0));
            emit Deserted();
            return;
        }

        paymentDeadlineBlock = block.number + paymentDurationBlocks;
        address newWinner = top10Bidders[currentWinnerIndex];
        emit WinnerAdvanced(newWinner, bidders[newWinner].revealedBid, paymentDeadlineBlock, fallbackCount);
    }

    // ─────────────────────────────────────────────────────────────
    // Retiros y Emergencias [E]
    // ─────────────────────────────────────────────────────────────
    function withdrawDeposit() external isFinalized {
        Bidder storage b = bidders[msg.sender];
        require(b.hasCommitted, "No participaste");
        require(!b.withdrawn, "Ya retirado/gestionado");
        require(!b.defaulted, "Default: fianza perdida");
        require(!b.depositLocked, "Aun bloqueado");

        uint256 amount;
        if (b.hasRevealed) {
            amount = deposit;
        } else {
            uint256 penalty = (deposit * UNREVEALED_PENALTY_BPS) / 10000;
            ownerProceeds += penalty;
            amount = deposit - penalty;
        }

        b.withdrawn = true;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer fallo");
    }

    // [E] MODIFICADO: Dead Man's Switch
    function emergencyWithdraw() external {
        // Se activa si han pasado miles de bloques sin éxito
        require(block.number > revealDeadlineBlock + EMERGENCY_TIMEOUT_BLOCKS, "Muy pronto para emergencia");
        require(!auctionSuccessful, "Subasta completada con exito");

        Bidder storage b = bidders[msg.sender];
        require(b.hasCommitted && !b.withdrawn, "Nada que retirar");

        // Rompe las reglas y devuelve el 100% como rescate
        b.withdrawn = true;
        b.depositLocked = false;
        
        (bool ok, ) = payable(msg.sender).call{value: deposit}("");
        require(ok, "Transfer fallo");
        
        emit EmergencyWithdraw(msg.sender, deposit);
    }
    function withdrawProceeds() external {
        require(msg.sender == owner, "Solo owner");
        uint256 amount = ownerProceeds;
        ownerProceeds = 0;
        (bool ok,) = payable(owner).call{value: amount}("");
        require(ok, "Transfer fallo");
    }

    // ─────────────────────────────────────────────────────────────
    // [E] MODIFICADO: Integración de Bot (Estándar Chainlink Keepers)
    // ─────────────────────────────────────────────────────────────
    
    /**
     * @notice El bot llama aquí gratis para ver si tiene que trabajar
     */
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        if (!finalized && block.number >= revealDeadlineBlock) {
            return (true, abi.encode(uint256(0))); // Acción 0: Finalize
        }
        if (finalized && !auctionSuccessful && !auctionDeserted && block.number > paymentDeadlineBlock) {
            return (true, abi.encode(uint256(1))); // Acción 1: Advance
        }
        return (false, "");
    }

    /**
     * @notice El bot ejecuta la transacción cobrando la recompensa
     */
    function performUpkeep(bytes calldata performData) external {
        require(msg.sender == authorizedKeeper, "No autorizado");
        uint256 action = abi.decode(performData, (uint256));
        if (action == 0) {
            this.finalize();
        } else if (action == 1) {
            this.advanceWinnerIfUnpaid();
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Internal Lógicas O(1) de Ranking [A]
    // ─────────────────────────────────────────────────────────────
    
    // Inserta manteniendo siempre un máximo de 10 elementos ordenados
    function _insertIntoTop10(address bidder) internal {
        uint256 insertIndex = top10Bidders.length;
        
        for(uint256 i = 0; i < top10Bidders.length; i++) {
            if(_isBetterBid(bidder, top10Bidders[i])) {
                insertIndex = i;
                break;
            }
        }

        if(insertIndex < 10) {
            if(top10Bidders.length < 10) {
                top10Bidders.push(address(0));
            }
            for(uint256 i = top10Bidders.length - 1; i > insertIndex; i--) {
                top10Bidders[i] = top10Bidders[i-1];
            }
            top10Bidders[insertIndex] = bidder;
        }
    }

    function _recalculateNextTop10() internal {
        delete top10Bidders; // Vaciamos el array
        currentWinnerIndex = 0;

        for(uint256 i = 0; i < allRevealedBidders.length; i++) {
            address addr = allRevealedBidders[i];
            if(!bidders[addr].defaulted && !bidders[addr].withdrawn) {
                _insertIntoTop10(addr);
            }
        }
    }

    function _isBetterBid(address a, address b) internal view returns (bool) {
        Bidder storage bidA = bidders[a];
        Bidder storage bidB = bidders[b];
        if (bidA.revealedBid > bidB.revealedBid) return true;
        // [B] Empate se decide por número de bloque
        if (bidA.revealedBid == bidB.revealedBid && bidA.commitBlock < bidB.commitBlock) return true;
        return false;
    }

    function _unlockAllDepositsExceptWinner(address winner) internal {
        for (uint256 i = 0; i < allRevealedBidders.length; i++) {
            address addr = allRevealedBidders[i];
            if (addr == winner) continue;
            bidders[addr].depositLocked = false;
        }
    }

    function _unlockAllDeposits() internal {
        for (uint256 i = 0; i < allRevealedBidders.length; i++) {
            bidders[allRevealedBidders[i]].depositLocked = false;
        }
    }
}
