// bindings of module 'vscode-test'
type options = {
  extensionDevelopmentPath: string,
  extensionTestsPath: string,
};

[@bs.module "vscode-test"]
external runTests: options => Promise.t(int) = "runTests";

let dirname: option(string) = [%bs.node __dirname];

switch (dirname) {
| None =>
  Js.log("Failed to read __dirname");
  Node.Process.exit(1);
| Some(dirname) =>
  // The folder containing the Extension Manifest package.json
  // Passed to `--extensionDevelopmentPath`
  let extensionDevelopmentPath = Node.Path.resolve(dirname, "../");
  // The path to the extension test script
  // Passed to --extensionTestsPath
  let extensionTestsPath = Node.Path.resolve(dirname, "./suite/index.js");
  // Download VS Code, unzip it and run the integration test
  runTests({extensionDevelopmentPath, extensionTestsPath})
  ->Promise.get(Node.Process.exit);
};