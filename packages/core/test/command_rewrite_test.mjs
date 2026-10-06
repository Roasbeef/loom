// Exercise the same closed identity decoder on the portable JavaScript target.
import { bounded_rewrite_keeps_original_coordinates_and_rejects_nesting_test } from '../build/dev/javascript/core/core/command_test.mjs';

bounded_rewrite_keeps_original_coordinates_and_rejects_nesting_test();
console.log('Portable Original/Rewrite identity and total decoder controls passed.');
