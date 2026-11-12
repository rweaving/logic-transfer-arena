import 'package:arena_core/arena_core.dart';

void main() {
  final ArenaTopology board = PresetBoards.latchVaultDuel();
  final ArenaState base = ArenaState.initial(board);
  ArenaSolver.deployPulser(board, base, ArenaSide.cyan, board.leftRails[1]);
  ArenaSolver.deployPulser(board, base, ArenaSide.amber, board.rightRails[2]);

  // Warmup JIT
  final ArenaState work = base.clone();
  for (int w = 0; w < 200; w++) {
    work.copyFrom(base);
    ArenaSolver.runUntilSettled(board, work, maxTicks: 340);
  }

  const int rollouts = 2000;
  final Stopwatch sw = Stopwatch()..start();
  int checksum = 0;
  for (int i = 0; i < rollouts; i++) {
    work.copyFrom(base);
    ArenaSolver.runUntilSettled(board, work, maxTicks: 340);
    checksum ^= work.nodeOut[board.busNodes[0]];
  }
  sw.stop();

  final double totalMs = sw.elapsedMicroseconds / 1000.0;
  final double usPerRollout = sw.elapsedMicroseconds / rollouts;
  // ignore: avoid_print
  print(
    'Simulated $rollouts full 340-tick rollouts (${board.nodeCount} nodes, ${board.edgeCount} wires) '
    'in ${totalMs.toStringAsFixed(2)} ms -> ${usPerRollout.toStringAsFixed(1)} µs / rollout (checksum=$checksum)',
  );
}
