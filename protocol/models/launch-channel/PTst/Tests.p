// Each probe adds an exact effect-history witness to the same normal case.
module ChannelSystem = { LaunchChannel, Scenario };
machine TestStartup { start state Init { entry { new Scenario(StartupCase); } } }
test tcStartup [main = TestStartup]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestStartup });
test tcProbeStartup [main = TestStartup]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestStartup });
machine TestReply { start state Init { entry { new Scenario(ReplyCase); } } }
test tcReply [main = TestReply]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestReply });
test tcProbeReply [main = TestReply]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestReply });
machine TestImmediate { start state Init { entry { new Scenario(ImmediateCase); } } }
test tcImmediate [main = TestImmediate]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestImmediate });
test tcProbeImmediate [main = TestImmediate]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestImmediate });
machine TestStale { start state Init { entry { new Scenario(StaleCase); } } }
test tcStale [main = TestStale]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestStale });
test tcProbeStale [main = TestStale]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestStale });
machine TestIdentity { start state Init { entry { new Scenario(IdentityCase); } } }
test tcIdentity [main = TestIdentity]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestIdentity });
test tcProbeIdentity [main = TestIdentity]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestIdentity });
machine TestTerminal { start state Init { entry { new Scenario(TerminalCase); } } }
test tcTerminal [main = TestTerminal]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestTerminal });
test tcProbeTerminal [main = TestTerminal]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestTerminal });
machine TestCancel { start state Init { entry { new Scenario(CancelCase); } } }
test tcCancel [main = TestCancel]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestCancel });
test tcProbeCancel [main = TestCancel]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestCancel });
machine TestDeath { start state Init { entry { new Scenario(DeathCase); } } }
test tcDeath [main = TestDeath]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestDeath });
test tcProbeDeath [main = TestDeath]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestDeath });
machine TestByte { start state Init { entry { new Scenario(ByteCase); } } }
test tcByte [main = TestByte]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestByte });
test tcProbeByte [main = TestByte]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestByte });
machine TestActive { start state Init { entry { new Scenario(ActiveCase); } } }
test tcActive [main = TestActive]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestActive });
test tcProbeActive [main = TestActive]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestActive });
machine TestReport { start state Init { entry { new Scenario(ReportCase); } } }
test tcReport [main = TestReport]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestReport });
test tcProbeReport [main = TestReport]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestReport });
machine TestLocal { start state Init { entry { new Scenario(LocalCase); } } }
test tcLocal [main = TestLocal]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestLocal });
test tcProbeLocal [main = TestLocal]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestLocal });
machine TestBoundary { start state Init { entry { new Scenario(BoundaryCase); } } }
test tcBoundary [main = TestBoundary]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestBoundary });
test tcProbeBoundary [main = TestBoundary]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestBoundary });
machine TestEnd { start state Init { entry { new Scenario(EndCase); } } }
test tcEnd [main = TestEnd]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestEnd });
test tcProbeEnd [main = TestEnd]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestEnd });

machine TestRetirement { start state Init { entry { new Scenario(RetirementCase); } } }
test tcRetirement [main = TestRetirement]: assert ChannelSafety, DirectedCompletion in (union ChannelSystem, { TestRetirement });
test tcProbeRetirement [main = TestRetirement]: assert ChannelSafety, DirectedCompletion, ChannelReachability in (union ChannelSystem, { TestRetirement });
