// The fixed frame bootstrap injects the pinned vendor into its Gleam runtime.
// No renderer state, validation or configuration policy lives in this file.
import mermaid from "mermaid";
import { start } from "../build/dev/javascript/web_mermaid/web_mermaid.mjs";

start(mermaid);
