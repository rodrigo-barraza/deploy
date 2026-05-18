#!/usr/bin/env npx ts-node
/**
 * Automated fixer for TS7006 (implicit any) and TS2322/TS2345 (string|undefined → string).
 *
 * Usage:  npx ts-node fix-implicit-any.ts <service-dir>
 *
 * Strategy:
 *   TS7006 — parse the parameter name from the error message, find it in the source line,
 *            and append `: any` after the identifier.
 *   TS2322 / TS2345 — these are context-dependent; skip for manual review.
 */

import { execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const serviceDir = process.argv[2];
if (!serviceDir) {
  console.error('Usage: npx ts-node fix-implicit-any.ts <service-dir>');
  process.exit(1);
}

const absDir = path.resolve(serviceDir);

// Run tsc --noEmit and capture errors
const raw = (() => {
  try {
    execSync(`npx tsc --noEmit`, { cwd: absDir, encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] });
    return '';
  } catch (err: any) {
    return (err.stdout || '') + (err.stderr || '');
  }
})();

interface TscError {
  file: string;
  line: number;
  col: number;
  code: string;
  message: string;
}

const errors: TscError[] = [];
const errorRegex = /^(.+?)\((\d+),(\d+)\): error (TS\d+): (.+)$/gm;
let match;
while ((match = errorRegex.exec(raw)) !== null) {
  errors.push({
    file: path.resolve(absDir, match[1]),
    line: parseInt(match[2], 10),
    col: parseInt(match[3], 10),
    code: match[4],
    message: match[5],
  });
}

console.log(`Found ${errors.length} total errors in ${absDir}`);

// Group errors by file, sorted by line DESC so we can edit bottom-up without shifting line numbers
const byFile = new Map<string, TscError[]>();
for (const err of errors) {
  if (!byFile.has(err.file)) byFile.set(err.file, []);
  byFile.get(err.file)!.push(err);
}

let fixedCount = 0;
let skippedCount = 0;

for (const [filePath, fileErrors] of byFile) {
  if (!fs.existsSync(filePath)) {
    console.warn(`  ⚠ File not found: ${filePath}`);
    continue;
  }

  const lines = fs.readFileSync(filePath, 'utf-8').split('\n');
  // Sort errors by line DESC then col DESC for bottom-up editing
  fileErrors.sort((a, b) => b.line - a.line || b.col - a.col);

  let modified = false;

  for (const err of fileErrors) {
    const lineIdx = err.line - 1;
    if (lineIdx < 0 || lineIdx >= lines.length) continue;
    const line = lines[lineIdx];

    if (err.code === 'TS7006') {
      // "Parameter 'xxx' implicitly has an 'any' type."
      const paramMatch = err.message.match(/Parameter '([^']+)'/);
      if (!paramMatch) { skippedCount++; continue; }
      const paramName = paramMatch[1];

      // Find the parameter at or near the column position and add `: any`
      // We need to find `paramName` without a type annotation following it
      // Possible patterns: (paramName, | (paramName) | paramName, | paramName)
      const col = err.col - 1; // 0-indexed
      
      // Check if the parameter name is at the expected column
      const paramAtCol = line.substring(col, col + paramName.length);
      if (paramAtCol === paramName) {
        const afterParam = col + paramName.length;
        const charAfter = line[afterParam];
        // Only add `: any` if the next char is , ) = or whitespace (no existing type annotation)
        if (charAfter === ',' || charAfter === ')' || charAfter === '=' || charAfter === ' ' || charAfter === undefined) {
          // Check it doesn't already have a type annotation
          const restOfLine = line.substring(afterParam);
          if (!restOfLine.startsWith(': ') && !restOfLine.startsWith(':')) {
            // Handle default values: paramName = defaultVal → paramName: any = defaultVal
            if (charAfter === ' ' && restOfLine.match(/^\s*=/)) {
              lines[lineIdx] = line.substring(0, afterParam) + ': any' + line.substring(afterParam);
            } else {
              lines[lineIdx] = line.substring(0, afterParam) + ': any' + line.substring(afterParam);
            }
            modified = true;
            fixedCount++;
            continue;
          }
        }
      }
      
      // Fallback: search the entire line for the parameter
      // Use regex to find un-typed parameter
      const patterns = [
        // Arrow function or regular function parameter
        new RegExp(`([({,]\\s*)${escapeRegex(paramName)}(\\s*[,)=])`, 'g'),
        // Destructured parameter 
        new RegExp(`([{,]\\s*)${escapeRegex(paramName)}(\\s*[,}])`, 'g'),
      ];
      
      let lineFixed = false;
      for (const pattern of patterns) {
        const lineStr = lines[lineIdx];
        if (pattern.test(lineStr)) {
          pattern.lastIndex = 0;
          lines[lineIdx] = lineStr.replace(pattern, (match, before, after) => {
            return `${before}${paramName}: any${after}`;
          });
          if (lines[lineIdx] !== lineStr) {
            modified = true;
            fixedCount++;
            lineFixed = true;
            break;
          }
        }
      }
      
      if (!lineFixed) {
        skippedCount++;
        console.log(`  ⚠ TS7006 skip: ${path.relative(absDir, filePath)}:${err.line} — param '${paramName}'`);
      }
    } else if (err.code === 'TS7053') {
      // Element implicitly has an 'any' type — usually bracket notation on typed object
      // Add `as any` or cast the expression. These are trickier.
      skippedCount++;
    } else if (err.code === 'TS2322' || err.code === 'TS2345') {
      // string | undefined → string
      // These need manual casting, skip for now
      skippedCount++;
    } else if (err.code === 'TS7031') {
      // Binding element 'xxx' implicitly has an 'any' type
      const paramMatch = err.message.match(/Binding element '([^']+)'/);
      if (!paramMatch) { skippedCount++; continue; }
      skippedCount++;
    } else {
      skippedCount++;
    }
  }

  if (modified) {
    fs.writeFileSync(filePath, lines.join('\n'), 'utf-8');
  }
}

console.log(`\n✔ Fixed: ${fixedCount}  ⚠ Skipped: ${skippedCount}`);

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
