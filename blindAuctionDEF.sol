// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BlindAuctionFinalV2
 * @notice Subasta sealed-bid (commit–reveal) con:
 *  - Fianza fija (deposit) elegida por el vendedor dentro de rangos del programa
 *  - Puja mínima = fianza
 *  - Ganador paga resto (bid - fianza). Si no paga -> pierde 100% y pasa al siguiente
 *  - No revelar -> penalización parcial (pierde menos que no pagar)
 *  - Empates: gana quien hizo COMMIT antes (no quien revela antes)
 *  - Pull payments (nadie devuelve en bucle): cada usuario retira su fianza
 *  - finalize() y advanceWinnerIfUnpaid() callable por cualquiera (liveness)
 *  - Incentivo simple para quien ejecuta el avance (recompensa)
 */
contract BlindAuctionFinalV2 {
    // ─────────────────────────────────────────────────────────────
    // Parámetros "del programa" (hardcoded): defendibles en presentación
    // ─────────────────────────────────────────────────────────────

    // Rango permitido de fianza (ajustable para hackathon)
    uint256 public constant MIN_DEPOSIT = 0.001 ether;
    uint256 public constant MAX_DEPOSIT = 10 ether;

    // Mínimos de tiempos para evitar abuso del vendedor
    uint256 public constant MIN_COMMIT_DURATION  = 5 minutes;
    uint256 public constant MIN_REVEAL_DURATION  = 5 minutes;
    uint256 public constant MIN_PAYMENT_DURATION = 5 minutes;

    // Límites razonables para escalabilidad/gas
    uint256 public constant MIN_MAX_BIDDERS = 10;
    uint256 public constant MAX_MAX_BIDDERS = 200;

    // Penalización por NO revelar (menos grave que no pagar)
    // 20% es defendible: castiga el "no cooperar", pero no es devastador por despiste.
    uint256 public constant UNREVEALED_PENALTY_BPS = 2000; // 20% en basis points (10000 = 100%)

    // Recompensa para quien llama a advanceWinnerIfUnpaid()
    // Pequeña (5%) para incentivar liveness sin crear un incentivo enorme.
    uint256 public constant ADVANCE_CALLER_BOUNTY_BPS = 500; // 5%

    // ─────────────────────────────────────────────────────────────
    // Config del vendedor (owner) para esta subasta concreta
    // ─────────────────────────────────────────────────────────────
    address public immutable owner;

    uint256 public immutable commitDeadline;
    uint256 public immutable revealDeadline;

    uint256 public immutable deposit;          // fianza fija = puja mínima
    uint256 public immutable paymentDuration;  // ventana de pago
    uint256 public immutable maxBidders;       // máximo de participantes
    uint256 public immutable maxFallbacks;     // 0 = ilimitado

    // ─────────────────────────────────────────────────────────────
    // Estado por bidder
    // ─────────────────────────────────────────────────────────────
    struct Bidder {
        bytes32 commitment;
        uint256 commitTime;     // tie-break: antes es mejor
        uint256 revealedBid;    // puja revelada
        bool hasCommitted;
        bool hasRevealed;       // reveal válido
        bool withdrawn;         // ya retiró / confiscado / gestionado
        bool depositLocked;     // bloqueado si está en ranking mientras se decide ganador
        bool defaulted;         // fue ganador pero no pagó (pierde 100%)
    }

    mapping(address => Bidder) public bidders;
    address[] public bidderList;

    // Ranking ordenado (desc por bid, y asc por commitTime en empate)
    address[] public rankedBidders;

    // ─────────────────────────────────────────────────────────────
    // Estado de subasta
    // ─────────────────────────────────────────────────────────────
    bool public finalized;
    bool public auctionSuccessful;
    bool public auctionDeserted;

    uint256 public currentWinnerIndex;
    uint256 public paymentDeadline;
    uint256 public fallbackCount;

    // Pull payments: saldo retirables
    uint256 public ownerProceeds;
    mapping(address => uint256) public rewards; // recompensas (caller bounty) retirables

    // ─────────────────────────────────────────────────────────────
    // Eventos
    // ─────────────────────────────────────────────────────────────
    event Committed(address indexed bidder, bytes32 commitment);
    event Revealed(address indexed bidder, uint256 bid);
    event Finalized(address indexed firstWinner, uint256 bid, uint256 paymentDeadline);
    event WinnerPaid(address indexed winner, uint256 totalPaid);
    event WinnerAdvanced(address indexed newWinner, uint256 bid, uint256 paymentDeadline, uint256 fallbackCount);
    event DepositWithdrawn(address indexed bidder, uint256 amount);
    event DepositConfiscated(address indexed bidder, uint256 amount, string reason);
    event RewardAccrued(address indexed caller, uint256 amount);
    event OwnerWithdrawn(uint256 amount);
    event RewardWithdrawn(address indexed caller, uint256 amount);
    event Deserted();

    // ─────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────
    modifier inCommitPhase() {
        require(block.timestamp < commitDeadline, "Commit cerrada");
        _;
    }

    modifier inRevealPhase() {
        require(block.timestamp >= commitDeadline, "Reveal no iniciada");
        require(block.timestamp < revealDeadline, "Reveal cerrada");
        _;
    }

    modifier afterReveal() {
        require(block.timestamp >= revealDeadline, "Reveal no terminado");
        _;
    }

    modifier isFinalized() {
        require(finalized, "No finalizado");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Solo owner");
        _;
    }

    // ─────────────────────────────────────────────────────────────
    // Constructor: el vendedor "publica" la subasta desplegando el contrato
    // ─────────────────────────────────────────────────────────────
    constructor(
        uint256 _commitDuration,
        uint256 _revealDuration,
        uint256 _deposit,
        uint256 _paymentDuration,
        uint256 _maxBidders,
        uint256 _maxFallbacks
    ) {
        // 1) Tiempos mínimos para evitar abuso del vendedor
        require(_commitDuration >= MIN_COMMIT_DURATION, "commitDuration muy corto");
        require(_revealDuration >= MIN_REVEAL_DURATION, "revealDuration muy corto");
        require(_paymentDuration >= MIN_PAYMENT_DURATION, "paymentDuration muy corto");

        // 5/8) Fianza acotada por el programa
        require(_deposit >= MIN_DEPOSIT, "deposit demasiado bajo");
        require(_deposit <= MAX_DEPOSIT, "deposit demasiado alto");

        // 7) maxBidders acotado
        require(_maxBidders >= MIN_MAX_BIDDERS, "maxBidders demasiado bajo");
        require(_maxBidders <= MAX_MAX_BIDDERS, "maxBidders demasiado alto");

        owner = msg.sender;

        commitDeadline = block.timestamp + _commitDuration;
        revealDeadline = commitDeadline + _revealDuration;

        deposit = _deposit;
        paymentDuration = _paymentDuration;
        maxBidders = _maxBidders;
        maxFallbacks = _maxFallbacks; // 0 => ilimitado
    }

    // ─────────────────────────────────────────────────────────────
    // Commit: entrar pagando fianza fija y enviando el hash
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Entrar en la subasta pagando EXACTAMENTE la fianza y enviando tu commitment.
     * @dev Commitment recomendado:
     *      keccak256(abi.encode(bidAmount, salt, msg.sender, address(this)))
     */
    function commit(bytes32 _commitment) external payable inCommitPhase {
        require(_commitment != bytes32(0), "Commitment invalido");
        require(bidderList.length < maxBidders, "Subasta llena");
        require(msg.value == deposit, "Debes pagar la fianza exacta");

        Bidder storage b = bidders[msg.sender];
        require(!b.hasCommitted, "Ya hiciste commit");

        b.commitment = _commitment;
        b.commitTime = block.timestamp; // tie-break por tiempo de commit
        b.hasCommitted = true;

        bidderList.push(msg.sender);

        emit Committed(msg.sender, _commitment);
    }

    // ─────────────────────────────────────────────────────────────
    // Reveal: publicar el bid y validar el commitment
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Revela tu puja real. Si es válida, entras en el ranking.
     * @dev En Ethereum el reveal es público sí o sí.
     */
    function reveal(uint256 _bidAmount, bytes32 _salt) external inRevealPhase {
        Bidder storage b = bidders[msg.sender];
        require(b.hasCommitted, "No participaste");
        require(!b.hasRevealed, "Ya revelaste");

        // Puja mínima = fianza
        require(_bidAmount >= deposit, "Bid < fianza");

        // Verificación: ligado a bidder y contrato (evita replay en otro contrato)
        bytes32 expected = keccak256(abi.encode(_bidAmount, _salt, msg.sender, address(this)));
        require(expected == b.commitment, "Reveal invalido");

        b.hasRevealed = true;
        b.revealedBid = _bidAmount;

        _insertIntoRanking(msg.sender);

        emit Revealed(msg.sender, _bidAmount);
    }

    // ─────────────────────────────────────────────────────────────
    // Finalize: tras reveal, fija el primer ganador y bloquea depósitos del ranking
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Finaliza la subasta (callable por cualquiera) para garantizar progreso.
     */
    function finalize() external afterReveal {
        require(!finalized, "Ya finalizado");
        finalized = true;

        if (rankedBidders.length == 0) {
            auctionDeserted = true;
            emit Deserted();
            return;
        }

        // Bloquea depósitos de quienes están en ranking hasta que haya ganador o desierta
        for (uint256 i = 0; i < rankedBidders.length; i++) {
            bidders[rankedBidders[i]].depositLocked = true;
        }

        currentWinnerIndex = 0;
        paymentDeadline = block.timestamp + paymentDuration;

        address first = rankedBidders[0];
        emit Finalized(first, bidders[first].revealedBid, paymentDeadline);
    }

    // ─────────────────────────────────────────────────────────────
    // Pago del ganador actual: paga bid - fianza
    // ─────────────────────────────────────────────────────────────

    function payWinningBid() external payable isFinalized {
        require(!auctionDeserted, "Subasta desierta");
        require(!auctionSuccessful, "Ya completada");
        require(currentWinnerIndex < rankedBidders.length, "Sin ganador");
        require(block.timestamp <= paymentDeadline, "Plazo expirado");

        address w = rankedBidders[currentWinnerIndex];
        require(msg.sender == w, "No eres el ganador actual");

        uint256 bidAmount = bidders[w].revealedBid;
        uint256 remaining = bidAmount > deposit ? bidAmount - deposit : 0;
        require(msg.value == remaining, "Cantidad incorrecta");

        // El owner cobra por pull payment: fianza + restante = bid total
        ownerProceeds += (deposit + msg.value);

        auctionSuccessful = true;

        // Desbloquea depósitos de todos menos el ganador (que no recupera fianza)
        _unlockAllRankedDepositsExceptWinner(w);

        // El ganador ya no retira
        bidders[w].withdrawn = true;

        emit WinnerPaid(w, deposit + msg.value);
    }

    // ─────────────────────────────────────────────────────────────
    // Fallback: si el ganador no paga, pierde 100% y pasa al siguiente
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Si el ganador no paga a tiempo:
     *   - Confisca 100% de la fianza (penalización fuerte)
     *   - Da una pequeña recompensa al caller (pull reward)
     *   - Avanza al siguiente ganador con un nuevo plazo de pago
     *   - Si se agota ranking o maxFallbacks -> desierta
     */
    function advanceWinnerIfUnpaid() external isFinalized {
        require(!auctionDeserted, "Ya desierta");
        require(!auctionSuccessful, "Ya completada");
        require(currentWinnerIndex < rankedBidders.length, "Sin ganador");
        require(block.timestamp > paymentDeadline, "Plazo aun activo");

        address defaulter = rankedBidders[currentWinnerIndex];
        Bidder storage bd = bidders[defaulter];
        require(!bd.withdrawn, "Ya gestionado");

        // Penalización 100%: pierde la fianza
        bd.withdrawn = true;
        bd.depositLocked = false;
        bd.defaulted = true;

        // Incentivo al caller: 5% de la fianza confiscada (pull)
        uint256 bounty = (deposit * ADVANCE_CALLER_BOUNTY_BPS) / 10000;
        uint256 rest = deposit - bounty;

        rewards[msg.sender] += bounty;
        ownerProceeds += rest;

        emit RewardAccrued(msg.sender, bounty);
        emit DepositConfiscated(defaulter, deposit, "winner did not pay");

        fallbackCount += 1;
        currentWinnerIndex += 1;

        bool noMore = currentWinnerIndex >= rankedBidders.length;
        bool maxReached = (maxFallbacks != 0 && fallbackCount >= maxFallbacks);

        if (noMore || maxReached) {
            auctionDeserted = true;
            _unlockAllRankedDepositsExceptWinner(address(0));
            emit Deserted();
            return;
        }

        paymentDeadline = block.timestamp + paymentDuration;

        address newWinner = rankedBidders[currentWinnerIndex];
        emit WinnerAdvanced(newWinner, bidders[newWinner].revealedBid, paymentDeadline, fallbackCount);
    }

    // ─────────────────────────────────────────────────────────────
    // Withdraw: devolución de fianza (pull payments), incluyendo no-reveal parcial
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Retira tu fianza (o parte si no revelaste).
     *
     * Casos:
     *  A) Revelaste válido y NO ganaste/NO default:
     *     - Puedes retirar la fianza cuando depositLocked=false (tras éxito o subasta desierta).
     *  B) NO revelaste:
     *     - Puedes retirar DESPUÉS de revealDeadline (y finalize) con penalización parcial:
     *       recuperas 80%, pierdes 20% (va al ownerProceeds).
     *  C) Ganador exitoso: no retira (su fianza forma parte del pago).
     *  D) Ganador que no paga (default): no retira (pierde 100%).
     */
    function withdrawDeposit() external isFinalized {
        Bidder storage b = bidders[msg.sender];
        require(b.hasCommitted, "No participaste");
        require(!b.withdrawn, "Ya retirado/gestionado");

        // Caso ganador exitoso
        if (auctionSuccessful) {
            address win = rankedBidders[currentWinnerIndex];
            require(msg.sender != win, "Ganador no retira");
        }

        // Caso default (ganador que no pago)
        require(!b.defaulted, "Default: fianza perdida");

        // Si está bloqueado por ranking, aún no puede retirar
        require(!b.depositLocked, "Aun bloqueado (ranking)");

        uint256 amount;

        if (b.hasRevealed) {
            // Perdedor que reveló correctamente: recupera 100%
            amount = deposit;
        } else {
            // No reveló: recupera solo una parte (penalización parcial)
            // Penalización 20% => recupera 80%
            uint256 penalty = (deposit * UNREVEALED_PENALTY_BPS) / 10000;
            uint256 refund = deposit - penalty;

            ownerProceeds += penalty;
            emit DepositConfiscated(msg.sender, penalty, "did not reveal");

            amount = refund;
        }

        b.withdrawn = true;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer fallo");

        emit DepositWithdrawn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────
    // Pull withdrawals: owner y recompensas
    // ─────────────────────────────────────────────────────────────

    function withdrawOwnerProceeds(uint256 amount) external onlyOwner {
        require(amount > 0, "amount=0");
        require(amount <= ownerProceeds, "Insuficiente");

        ownerProceeds -= amount;

        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "Transfer fallo");

        emit OwnerWithdrawn(amount);
    }

    function withdrawReward(uint256 amount) external {
        require(amount > 0, "amount=0");
        require(amount <= rewards[msg.sender], "Insuficiente");

        rewards[msg.sender] -= amount;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer fallo");

        emit RewardWithdrawn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────
    // Ranking: inserción ordenada con tie-break por commitTime
    // ─────────────────────────────────────────────────────────────

    /**
     * Orden: mayor bid primero.
     * Empate de bid: gana quien committeó antes (commitTime menor).
     */
    function _insertIntoRanking(address bidder) internal {
        rankedBidders.push(bidder);
        uint256 i = rankedBidders.length - 1;

        while (i > 0) {
            address prev = rankedBidders[i - 1];

            uint256 bidI = bidders[bidder].revealedBid;
            uint256 bidP = bidders[prev].revealedBid;

            if (bidI > bidP) {
                // swap por mayor bid
            } else if (bidI == bidP) {
                // empate: comparar commitTime
                if (bidders[bidder].commitTime >= bidders[prev].commitTime) {
                    break; // bidder no es "mejor" que prev
                }
                // si commitTime menor, sube
            } else {
                break; // bid menor, no sube
            }

            // swap
            rankedBidders[i] = prev;
            rankedBidders[i - 1] = bidder;
            i--;
        }
    }

    function _unlockAllRankedDepositsExceptWinner(address winner) internal {
        for (uint256 i = 0; i < rankedBidders.length; i++) {
            address addr = rankedBidders[i];
            if (addr == winner) continue;
            bidders[addr].depositLocked = false;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Views / helpers
    // ─────────────────────────────────────────────────────────────

    function hashBid(uint256 bidAmount, bytes32 salt, address bidder) external view returns (bytes32) {
        return keccak256(abi.encode(bidAmount, salt, bidder, address(this)));
    }

    function getBidderCount() external view returns (uint256) {
        return bidderList.length;
    }

    function getRankedCount() external view returns (uint256) {
        return rankedBidders.length;
    }

    function currentWinner() external view returns (address) {
        if (!finalized || auctionDeserted || rankedBidders.length == 0) return address(0);
        if (currentWinnerIndex >= rankedBidders.length) return address(0);
        return rankedBidders[currentWinnerIndex];
    }

    function timeLeft() external view returns (uint256 commitLeft, uint256 revealLeft, uint256 payLeft) {
        commitLeft = block.timestamp < commitDeadline ? commitDeadline - block.timestamp : 0;
        revealLeft = block.timestamp < revealDeadline ? revealDeadline - block.timestamp : 0;
        payLeft = (finalized && !auctionDeserted && !auctionSuccessful && block.timestamp < paymentDeadline)
            ? paymentDeadline - block.timestamp
            : 0;
    }
    
    receive() external payable {}
}