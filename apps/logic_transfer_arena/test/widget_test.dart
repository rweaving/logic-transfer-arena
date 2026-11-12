import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logic_transfer_arena/main.dart';

void main() {
  testWidgets(
      'Logic Transfer Arena supports Pre-Round Gate Prep, Sandbox Editor, and 1v1 Online Room Lobby',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pumpWidget(const LogicTransferArenaApp());
    await tester.pump(const Duration(milliseconds: 100));

    // 1. Starts in 10.0s Pre-Round Gate Configuration Countdown with real logic gate palette.
    expect(find.text('GATE PREP COUNTDOWN'), findsOneWidget);
    expect(find.text('GATE PALETTE:'), findsOneWidget);
    expect(find.text('NAND'), findsOneWidget);
    expect(find.text('NOR'), findsOneWidget);
    expect(find.text('START ROUND →'), findsOneWidget);

    // Select NAND tool and lock in round start.
    await tester.tap(find.text('NAND'));
    await tester.pump();

    await tester.tap(find.text('START ROUND →'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('TRANSFER LIVE'), findsOneWidget);

    // 2. Switch to Interactive Sandbox Editor mode.
    await tester.tap(find.text('Sandbox Editor'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('SANDBOX ARCHITECT'), findsOneWidget);
    expect(find.text('EDITOR:'), findsOneWidget);
    expect(find.text('MIRROR: ON'), findsOneWidget);
    expect(find.text('Play vs AI →'), findsOneWidget);

    // 3. Switch to 1v1 Online Room Lobby.
    await tester.tap(find.text('1v1 Online Room'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('1v1 ONLINE LOCKSTEP ROOM LOBBY'), findsOneWidget);
    expect(find.text('Create 4-Char Room'), findsOneWidget);

    // 4. Switch to Daily Underdog mode -> starts fresh Pre-Round Gate Prep Countdown.
    await tester.tap(find.text('Daily Underdog'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('UNIT 742'), findsOneWidget);
    expect(find.text('GATE PREP COUNTDOWN'), findsOneWidget);
  });
}
