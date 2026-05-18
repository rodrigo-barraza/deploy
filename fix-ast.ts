import { Project, SyntaxKind, Node, ArrayLiteralExpression } from 'ts-morph';
import * as path from 'path';

const tsconfigPath = process.argv[2];
if (!tsconfigPath) {
  console.error('Usage: npx ts-node fix-ast.ts <path-to-tsconfig.json>');
  process.exit(1);
}

const project = new Project({
  tsConfigFilePath: tsconfigPath,
});

const sourceFiles = project.getSourceFiles();
console.log(`Analyzing ${sourceFiles.length} files in ${tsconfigPath}...`);

let totalParamFixes = 0;
let totalVarFixes = 0;

for (const sf of sourceFiles) {
  let changed = false;

  // 1. Fix implicit any on Parameters
  const parameters = sf.getDescendantsOfKind(SyntaxKind.Parameter);
  for (const param of parameters) {
    if (!param.getTypeNode()) {
      param.setType('any');
      changed = true;
      totalParamFixes++;
    }
  }

  // 2. Fix implicit any on Variables (let x; or let x = [])
  const variables = sf.getDescendantsOfKind(SyntaxKind.VariableDeclaration);
  for (const varDecl of variables) {
    if (!varDecl.getTypeNode()) {
      // Check if inside for-of loop
      const parent = varDecl.getParent();
      const grandParent = parent ? parent.getParent() : null;
      if (grandParent && Node.isForOfStatement(grandParent)) {
        continue; // TS doesn't allow type annotations here
      }
      
      const initializer = varDecl.getInitializer();
      if (!initializer) {
        // let x; -> let x: any;
        varDecl.setType('any');
        changed = true;
        totalVarFixes++;
      } else if (Node.isArrayLiteralExpression(initializer)) {
        // let arr = []; -> let arr: any[] = [];
        if (initializer.getElements().length === 0) {
          varDecl.setType('any[]');
          changed = true;
          totalVarFixes++;
        }
      }
    }
  }

  if (changed) {
    sf.saveSync();
  }
}

console.log(`\n✔ AST fixes applied: ${totalParamFixes} parameters, ${totalVarFixes} variables.`);
