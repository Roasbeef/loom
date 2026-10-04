module ProductSystem = { Owner, Executor, Helper, ProductOwner, ProductExecutor, ProductScenario };
machine TestProductLifecycle { start state Init { entry { new ProductScenario(ProductLifecycle); } } }
test tcProductLifecycle [main = TestProductLifecycle]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, DirectedProgress in (union ProductSystem, { TestProductLifecycle });
machine TestProductOfferConflict { start state Init { entry { new ProductScenario(ProductOfferConflict); } } }
test tcProductOfferConflict [main = TestProductOfferConflict]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, DirectedProgress in (union ProductSystem, { TestProductOfferConflict });
machine TestProductResourceUnknown { start state Init { entry { new ProductScenario(ProductResourceUnknown); } } }
test tcProductResourceUnknown [main = TestProductResourceUnknown]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, DirectedProgress in (union ProductSystem, { TestProductResourceUnknown });
machine TestProductLeaseRecovery { start state Init { entry { new ProductScenario(ProductLeaseRecovery); } } }
test tcProductLeaseRecovery [main = TestProductLeaseRecovery]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, DirectedProgress in (union ProductSystem, { TestProductLeaseRecovery });
machine TestProductLaunchLoss { start state Init { entry { new ProductScenario(ProductLaunchLoss); } } }
test tcProductLaunchLoss [main = TestProductLaunchLoss]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, DirectedProgress in (union ProductSystem, { TestProductLaunchLoss });
machine TestProductChildAddresses { start state Init { entry { new ProductScenario(ProductChildAddresses); } } }
test tcProductChildAddresses [main = TestProductChildAddresses]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, DirectedProgress in (union ProductSystem, { TestProductChildAddresses });
machine TestProductChildOnlyRecovery { start state Init { entry { new ProductScenario(ProductChildOnlyRecovery); } } }
test tcProductChildOnlyRecovery [main = TestProductChildOnlyRecovery]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, DirectedProgress in (union ProductSystem, { TestProductChildOnlyRecovery });
machine TestProductFaults { start state Init { entry { new ProductScenario(ProductFaults); } } }
test tcProductFaults [main = TestProductFaults]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety in (union ProductSystem, { TestProductFaults });
