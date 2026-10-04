module ProductSystem = { Owner, Executor, Helper, ProductOwner, ProductExecutor, ProductScenario };
machine TestProductLifecycle { start state Init { entry { new ProductScenario(ProductLifecycle); } } }
test tcProductLifecycle [main = TestProductLifecycle]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductLifecycle });
machine TestProductOfferConflict { start state Init { entry { new ProductScenario(ProductOfferConflict); } } }
test tcProductOfferConflict [main = TestProductOfferConflict]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductOfferConflict });
machine TestProductResourceUnknown { start state Init { entry { new ProductScenario(ProductResourceUnknown); } } }
test tcProductResourceUnknown [main = TestProductResourceUnknown]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductResourceUnknown });
machine TestProductLeaseRecovery { start state Init { entry { new ProductScenario(ProductLeaseRecovery); } } }
test tcProductLeaseRecovery [main = TestProductLeaseRecovery]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductLeaseRecovery });
machine TestProductLaunchLoss { start state Init { entry { new ProductScenario(ProductLaunchLoss); } } }
test tcProductLaunchLoss [main = TestProductLaunchLoss]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductLaunchLoss });
machine TestProductChildAddresses { start state Init { entry { new ProductScenario(ProductChildAddresses); } } }
test tcProductChildAddresses [main = TestProductChildAddresses]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductChildAddresses });
machine TestProductChildOnlyRecovery { start state Init { entry { new ProductScenario(ProductChildOnlyRecovery); } } }
test tcProductChildOnlyRecovery [main = TestProductChildOnlyRecovery]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductChildOnlyRecovery });
machine TestProductFaults { start state Init { entry { new ProductScenario(ProductFaults); } } }
test tcProductFaults [main = TestProductFaults]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety in (union ProductSystem, { TestProductFaults });
machine TestProductCompileUnknown { start state Init { entry { new ProductScenario(ProductCompileUnknown); } } }
test tcProductCompileUnknown [main = TestProductCompileUnknown]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductCompileUnknown });
machine TestProductCompileReadyRecovery { start state Init { entry { new ProductScenario(ProductCompileLeaseRecovery); } } }
test tcProductCompileReadyRecovery [main = TestProductCompileReadyRecovery]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductCompileReadyRecovery });
machine TestProductDeadResource { start state Init { entry { new ProductScenario(ProductDeadResource); } } }
test tcProductDeadResource [main = TestProductDeadResource]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductDeadResource });
machine TestProductForeignAssociation { start state Init { entry { new ProductScenario(ProductForeignAssociation); } } }
test tcProductForeignAssociation [main = TestProductForeignAssociation]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductForeignAssociation });
machine TestProductBadFingerprint { start state Init { entry { new ProductScenario(ProductBadFingerprint); } } }
test tcProductBadFingerprint [main = TestProductBadFingerprint]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductBadFingerprint });
machine TestProductBudgetZero { start state Init { entry { new ProductScenario(ProductBudgetZero); } } }
test tcProductBudgetZero [main = TestProductBudgetZero]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductBudgetZero });
machine TestProductBudgetBelowOne { start state Init { entry { new ProductScenario(ProductBudgetBelowOne); } } }
test tcProductBudgetBelowOne [main = TestProductBudgetBelowOne]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductBudgetBelowOne });
machine TestProductBudgetOne { start state Init { entry { new ProductScenario(ProductBudgetOne); } } }
test tcProductBudgetOne [main = TestProductBudgetOne]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductBudgetOne });
machine TestProductBudgetBelowCap { start state Init { entry { new ProductScenario(ProductBudgetBelowCap); } } }
test tcProductBudgetBelowCap [main = TestProductBudgetBelowCap]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductBudgetBelowCap });
machine TestProductBudgetCap { start state Init { entry { new ProductScenario(ProductBudgetCap); } } }
test tcProductBudgetCap [main = TestProductBudgetCap]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductBudgetCap });
machine TestProductBudgetCold { start state Init { entry { new ProductScenario(ProductBudgetCold); } } }
test tcProductBudgetCold [main = TestProductBudgetCold]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductBudgetCold });
machine TestProductExpiredOffer { start state Init { entry { new ProductScenario(ProductExpiredOffer); } } }
test tcProductExpiredOffer [main = TestProductExpiredOffer]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductExpiredOffer });
machine TestProductPostSendDelay { start state Init { entry { new ProductScenario(ProductPostSendDelay); } } }
test tcProductPostSendDelay [main = TestProductPostSendDelay]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductPostSendDelay });
machine TestProductColdRun { start state Init { entry { new ProductScenario(ProductColdRun); } } }
test tcProductColdRun [main = TestProductColdRun]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductColdRun });
machine TestProductBudgetReduced { start state Init { entry { new ProductScenario(ProductBudgetReduced); } } }
test tcProductBudgetReduced [main = TestProductBudgetReduced]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductBudgetReduced });
machine TestProductForeignArtifact { start state Init { entry { new ProductScenario(ProductForeignArtifact); } } }
test tcProductForeignArtifact [main = TestProductForeignArtifact]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, DirectedProgress in (union ProductSystem, { TestProductForeignArtifact });
machine TestProductForeignNativeTerminal { start state Init { entry { new ProductScenario(ProductForeignNativeTerminal); } } }
test tcProductForeignNativeTerminal [main = TestProductForeignNativeTerminal]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ForeignTerminalRefusalSafety, DirectedProgress in (union ProductSystem, { TestProductForeignNativeTerminal });
