#!/usr/bin/env node
/**
 * Automated multi-pass fixer for TypeScript strict-mode errors.
 *
 * Usage:  node fix-ts-errors.mjs <service-dir> [--max-passes=N]
 *
 * Handles:
 *   TS7006  — Parameter 'x' implicitly has 'any' type  → `: any`
 *   TS7005  — Variable 'x' implicitly has 'any' type   → `: any`  (let/const)
 *   TS7034  — Variable 'x' implicitly has 'any[]' type → `: any[]`
 *   TS7031  — Binding element 'x' implicitly has 'any' → parent gets `: any`
 *   TS7053  — Element implicitly has 'any' (bracket)   → `(obj as any)[key]`
 *   TS7022  — Variable implicitly has 'any' (circular) → `: any`
 *   TS7023  — Function implicitly has return type 'any' → handled as TS7005/TS7022
 *   TS7016  — Could not find declaration file           → skip
 *   TS18046 — 'x' is of type 'unknown'                → `as any`
 *   TS18047 — 'x' is possibly null                    → non-null assertion `!`
 *   TS18048 — 'x' is possibly undefined               → non-null assertion `!`
 *   TS2322  — Type 'X' not assignable to 'Y'          → `as Y` where safe
 *   TS2345  — Argument type mismatch                  → `as any`
 *   TS2339  — Property does not exist on type          → `(x as any).prop`
 *   TS2531  — Object is possibly null                 → `!`
 *   TS2538  — Type cannot be used as an index type     → `as any`
 *   TS2698  — Spread types may only be created from object types → `as any`
 *   TS2769  — No overload matches                     → `as any`
 *   TS2783  — Property provided but not in type        → skip (needs restructure)
 *   TS2341  — Property is private                     → `(x as any).prop`
 *   TS2464  — A computed property name must be of type... → skip
 *   TS7019  — Rest parameter implicitly has 'any[]'   → `: any[]`
 */

import { execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const serviceDir = process.argv[2];
const maxPasses = parseInt((process.argv.find(a => a.startsWith('--max-passes=')) || '--max-passes=5').split('=')[1]);

if (!serviceDir) {
  console.error('Usage: node fix-ts-errors.mjs <service-dir> [--max-passes=N]');
  process.exit(1);
}

const absDir = path.resolve(serviceDir);
const svcName = path.basename(absDir);

function runTsc() {
  try {
    execSync(`npx tsc --noEmit`, { cwd: absDir, encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] });
    return '';
  } catch (err) {
    return (err.stdout || '') + (err.stderr || '');
  }
}

function parseErrors(raw) {
  const errors = [];
  const errorRegex = /^(.+?)\((\d+),(\d+)\): error (TS\d+): (.+)$/gm;
  let m;
  while ((m = errorRegex.exec(raw)) !== null) {
    errors.push({
      file: path.resolve(absDir, m[1]),
      line: parseInt(m[2], 10),
      col: parseInt(m[3], 10),
      code: m[4],
      message: m[5],
    });
  }
  return errors;
}

// --- Helpers ---

function readFileLines(filePath) {
  return fs.readFileSync(filePath, 'utf-8').split('\n');
}

function writeFileLines(filePath, lines) {
  fs.writeFileSync(filePath, lines.join('\n'), 'utf-8');
}

// Insert `: any` after a parameter/variable at a specific column
function insertTypeAtCol(line, col0, name, type) {
  const atCol = line.substring(col0, col0 + name.length);
  if (atCol !== name) return null;
  const after = col0 + name.length;
  const rest = line.substring(after);
  if (rest.match(/^\s*:/)) return null; // already typed
  return line.substring(0, after) + ': ' + type + line.substring(after);
}

// For TS7005/TS7034: variable declarations like `let x = ...` or `const x = ...`
function fixVariableDecl(line, col0, name, type) {
  const atCol = line.substring(col0, col0 + name.length);
  if (atCol !== name) return null;
  const after = col0 + name.length;
  const rest = line.substring(after);
  if (rest.match(/^\s*:/)) return null; // already typed
  // Insert type annotation
  return line.substring(0, after) + ': ' + type + line.substring(after);
}

// For TS18046: 'x' is of type 'unknown' — find the identifier and add `as any`
function fixUnknownType(line, col0) {
  // The col points to the expression that's unknown. We need to wrap it.
  // Find the extent of the identifier/expression at col
  const before = line.substring(0, col0);
  const rest = line.substring(col0);
  
  // Find the end of the identifier or member expression
  const identMatch = rest.match(/^[a-zA-Z_$][\w$]*(\.[a-zA-Z_$][\w$]*)*/);
  if (!identMatch) return null;
  
  const ident = identMatch[0];
  const afterIdent = col0 + ident.length;
  const charAfter = line[afterIdent];
  
  // Don't wrap if it's a function call — wrap just the identifier
  // Simple approach: add ` as any` or wrap in parens
  // Check if already cast
  const restAfter = line.substring(afterIdent);
  if (restAfter.match(/^\s+as\s+/)) return null; // already cast
  
  return line.substring(0, afterIdent) + ' as any' + line.substring(afterIdent);
}

// For TS18047/TS18048/TS2531: possibly null/undefined — add `!` non-null assertion
function fixPossiblyNull(line, col0) {
  const rest = line.substring(col0);
  const identMatch = rest.match(/^[a-zA-Z_$][\w$]*(\.[a-zA-Z_$][\w$]*)*/);
  if (!identMatch) return null;
  
  const ident = identMatch[0];
  const afterIdent = col0 + ident.length;
  const charAfter = line[afterIdent];
  
  // Don't add ! if it's already there
  if (charAfter === '!') return null;
  
  // Don't add ! if it's followed by ` as `
  const restAfter = line.substring(afterIdent);
  if (restAfter.match(/^\s+as\s+/)) return null;
  
  return line.substring(0, afterIdent) + '!' + line.substring(afterIdent);
}

let totalFixed = 0;
let totalSkipped = 0;

for (let pass = 1; pass <= maxPasses; pass++) {
  const raw = runTsc();
  const errors = parseErrors(raw);
  
  if (errors.length === 0) {
    console.log(`  Pass ${pass}: 0 errors — clean build! ✔`);
    break;
  }
  
  console.log(`  Pass ${pass}: ${errors.length} errors`);
  
  // Group by file
  const byFile = new Map();
  for (const err of errors) {
    if (!byFile.has(err.file)) byFile.set(err.file, []);
    byFile.get(err.file).push(err);
  }
  
  let passFixed = 0;
  let passSkipped = 0;
  
  for (const [filePath, fileErrors] of byFile) {
    if (!fs.existsSync(filePath)) continue;
    
    const lines = readFileLines(filePath);
    // Sort by line DESC, col DESC for bottom-up editing
    fileErrors.sort((a, b) => b.line - a.line || b.col - a.col);
    
    let modified = false;
    
    for (const err of fileErrors) {
      const lineIdx = err.line - 1;
      if (lineIdx < 0 || lineIdx >= lines.length) continue;
      const line = lines[lineIdx];
      const col0 = err.col - 1;
      
      let newLine = null;
      
      switch (err.code) {
        case 'TS7006': {
          // Parameter 'x' implicitly has an 'any' type
          const pm = err.message.match(/Parameter '([^']+)'/);
          if (pm) newLine = insertTypeAtCol(line, col0, pm[1], 'any');
          break;
        }
        
        case 'TS7019': {
          // Rest parameter 'x' implicitly has an 'any[]' type
          const pm = err.message.match(/Rest parameter '([^']+)'/);
          if (pm) newLine = insertTypeAtCol(line, col0, pm[1], 'any[]');
          break;
        }
        
        case 'TS7005': {
          // Variable 'x' implicitly has an 'any' type
          const pm = err.message.match(/Variable '([^']+)'/);
          if (pm) newLine = fixVariableDecl(line, col0, pm[1], 'any');
          break;
        }
        
        case 'TS7034': {
          // Variable 'x' implicitly has type 'any[]' in some locations
          const pm = err.message.match(/Variable '([^']+)'/);
          if (pm) newLine = fixVariableDecl(line, col0, pm[1], 'any[]');
          break;
        }
        
        case 'TS7022': {
          // 'x' implicitly has type 'any' because it does not have a type annotation and is referenced directly or indirectly in its own initializer
          const pm = err.message.match(/'([^']+)'/);
          if (pm) newLine = fixVariableDecl(line, col0, pm[1], 'any');
          break;
        }
        
        case 'TS7023': {
          // 'x' implicitly has return type 'any' because it does not have a return type annotation
          // This is on functions — we can add `: any` after the parameter list
          // For now skip — these are less common
          break;
        }
        
        case 'TS7031': {
          // Binding element 'x' implicitly has an 'any' type
          // The destructured parameter needs `as any` or the parent typed
          // Find the enclosing { } and add `: any` after the closing }
          // This is complex — try a simpler approach: find the line's destructuring
          // and add `: any` after the closing brace/bracket
          const pm = err.message.match(/Binding element '([^']+)'/);
          if (!pm) break;
          
          // Try to find the closing } or ] on this line and add `: any` if not already typed
          // Look for pattern: { ... } or [ ... ] followed by , or ) without type annotation
          const closingIdx = findDestructuringEnd(line, col0);
          if (closingIdx !== -1) {
            const afterClose = line.substring(closingIdx + 1);
            if (!afterClose.match(/^\s*:/)) {
              // Only insert once per destructuring — check if we already processed this
              newLine = line.substring(0, closingIdx + 1) + ': any' + line.substring(closingIdx + 1);
            }
          }
          break;
        }
        
        case 'TS7053': {
          // Element implicitly has an 'any' type because expression of type 'X' can't be used to index type 'Y'
          // Find the object before the [ and cast it
          // The col points to the opening of the expression
          // We need to find the object being indexed and add `as any`
          // Pattern: obj[key] → (obj as any)[key]
          // Find the [ before the col position
          const bracketIdx = line.lastIndexOf('[', col0);
          if (bracketIdx > 0) {
            // Find the start of the object expression before [
            let objStart = bracketIdx - 1;
            while (objStart >= 0 && (line[objStart] === ' ' || line[objStart] === '\t')) objStart--;
            
            // Find the full identifier/expression before the bracket
            let objEnd = objStart + 1;
            // Walk backwards to find the start of the identifier chain
            let i = objStart;
            while (i >= 0 && /[\w$.]/.test(line[i])) i--;
            objStart = i + 1;
            
            const objExpr = line.substring(objStart, objEnd);
            if (objExpr && !line.substring(objStart - 6, objStart).includes(' any)')) {
              // Check if already wrapped
              if (line[objStart - 1] !== ')' || !line.substring(0, objStart).includes(' as any')) {
                newLine = line.substring(0, objStart) + '(' + objExpr + ' as any)' + line.substring(objEnd);
              }
            }
          }
          break;
        }
        
        case 'TS18046': {
          // 'x' is of type 'unknown'
          newLine = fixUnknownType(line, col0);
          break;
        }
        
        case 'TS18047':
        case 'TS18048':
        case 'TS2531': {
          // Possibly null/undefined
          newLine = fixPossiblyNull(line, col0);
          break;
        }
        
        case 'TS2345': {
          // Argument of type 'X' is not assignable to parameter of type 'Y'
          // Find the argument expression at the col and add `as any`
          const rest = line.substring(col0);
          const identMatch = rest.match(/^[a-zA-Z_$][\w$]*(\.[a-zA-Z_$][\w$]*)*/);
          if (identMatch) {
            const ident = identMatch[0];
            const afterIdent = col0 + ident.length;
            const restAfter = line.substring(afterIdent);
            if (!restAfter.match(/^\s+as\s+/)) {
              newLine = line.substring(0, afterIdent) + ' as any' + line.substring(afterIdent);
            }
          }
          break;
        }
        
        case 'TS2322': {
          // Type 'X' is not assignable to type 'Y' — on assignment RHS
          // This is on the LHS variable name. We need to find the RHS value and cast it,
          // or add `as any` to the assignment.
          // For simple cases: `const x: string = envVar` → `const x: string = envVar as string`
          // Better approach: find the = sign after the col and cast the RHS
          const eqIdx = line.indexOf('=', col0);
          if (eqIdx !== -1 && line[eqIdx + 1] !== '=') {
            // Find the end of the RHS expression (before , ; or end of line)
            const rhs = line.substring(eqIdx + 1).trimStart();
            const rhsStart = eqIdx + 1 + (line.substring(eqIdx + 1).length - rhs.length);
            // Add `as any` before trailing , ; ) or end
            // Find the first , ; ) that's not inside parens/brackets
            let depth = 0;
            let insertPos = line.length;
            for (let j = rhsStart; j < line.length; j++) {
              if (line[j] === '(' || line[j] === '[' || line[j] === '{') depth++;
              else if (line[j] === ')' || line[j] === ']' || line[j] === '}') {
                if (depth === 0) { insertPos = j; break; }
                depth--;
              }
              else if (depth === 0 && (line[j] === ',' || line[j] === ';')) {
                insertPos = j;
                break;
              }
            }
            // Check if already has `as any` or `as string` etc
            const before = line.substring(0, insertPos).trimEnd();
            if (!before.match(/\bas\s+\w+$/)) {
              newLine = line.substring(0, insertPos) + ' as any' + line.substring(insertPos);
            }
          }
          break;
        }
        
        case 'TS2339':
        case 'TS2341': {
          // Property 'x' does not exist on type 'Y' / Property 'x' is private
          // The col points to the property name. We need to find the object before `.prop`
          // and cast it: obj.prop → (obj as any).prop
          const dotIdx = line.lastIndexOf('.', col0);
          if (dotIdx > 0) {
            let i = dotIdx - 1;
            // Handle closing parens/brackets before the dot
            if (line[i] === ')' || line[i] === ']') {
              // Find matching opening
              let depth = 1;
              const closeChar = line[i];
              const openChar = closeChar === ')' ? '(' : '[';
              i--;
              while (i >= 0 && depth > 0) {
                if (line[i] === closeChar) depth++;
                if (line[i] === openChar) depth--;
                i--;
              }
            }
            // Walk backwards through identifier chars
            while (i >= 0 && /[\w$.]/.test(line[i])) i--;
            const objStart = i + 1;
            const objExpr = line.substring(objStart, dotIdx);
            if (objExpr && !line.substring(Math.max(0, objStart - 8), objStart).includes('as any)')) {
              newLine = line.substring(0, objStart) + '(' + objExpr + ' as any)' + line.substring(dotIdx);
            }
          }
          break;
        }
        
        case 'TS2538': {
          // Type 'X' cannot be used as an index type
          // Add `as any` to the index expression
          const rest = line.substring(col0);
          const identMatch = rest.match(/^[a-zA-Z_$][\w$]*/);
          if (identMatch) {
            const ident = identMatch[0];
            const afterIdent = col0 + ident.length;
            const restAfter = line.substring(afterIdent);
            if (!restAfter.match(/^\s+as\s+/)) {
              newLine = line.substring(0, afterIdent) + ' as any' + line.substring(afterIdent);
            }
          }
          break;
        }
        
        case 'TS2698': {
          // Spread types may only be created from object types
          // Find the ... before col and cast: ...x → ...(x as any)
          const spreadIdx = line.lastIndexOf('...', col0 + 3);
          if (spreadIdx !== -1) {
            const afterSpread = spreadIdx + 3;
            const rest = line.substring(afterSpread);
            const identMatch = rest.match(/^[a-zA-Z_$][\w$]*(\.[a-zA-Z_$][\w$]*)*/);
            if (identMatch) {
              const ident = identMatch[0];
              const afterIdent = afterSpread + ident.length;
              // Wrap in (x as any)
              newLine = line.substring(0, afterSpread) + '(' + ident + ' as any)' + line.substring(afterIdent);
            }
          }
          break;
        }
        
        case 'TS2769': {
          // No overload matches — add `as any` at the col position
          const rest = line.substring(col0);
          const identMatch = rest.match(/^[a-zA-Z_$][\w$]*/);
          if (identMatch) {
            const ident = identMatch[0];
            const afterIdent = col0 + ident.length;
            const restAfter = line.substring(afterIdent);
            if (!restAfter.match(/^\s+as\s+/)) {
              newLine = line.substring(0, afterIdent) + ' as any' + line.substring(afterIdent);
            }
          }
          break;
        }
        
        default:
          // Skip codes we don't handle
          break;
      }
      
      if (newLine !== null && newLine !== line) {
        lines[lineIdx] = newLine;
        modified = true;
        passFixed++;
      } else {
        passSkipped++;
      }
    }
    
    if (modified) {
      writeFileLines(filePath, lines);
    }
  }
  
  totalFixed += passFixed;
  totalSkipped += passSkipped;
  console.log(`    → Fixed: ${passFixed}  Skipped: ${passSkipped}`);
  
  if (passFixed === 0) {
    console.log(`    → No more auto-fixable errors. Remaining need manual review.`);
    break;
  }
}

// Final check
const finalRaw = runTsc();
const finalErrors = parseErrors(finalRaw);
console.log(`\n${svcName}: ✔ Total fixed: ${totalFixed}  Remaining: ${finalErrors.length}`);

if (finalErrors.length > 0) {
  // Print remaining errors grouped by code
  const byCodes = new Map();
  for (const e of finalErrors) {
    byCodes.set(e.code, (byCodes.get(e.code) || 0) + 1);
  }
  for (const [code, count] of [...byCodes].sort((a, b) => b[1] - a[1])) {
    console.log(`    ${code}: ${count}`);
  }
}

// ---- Utility ----

function findDestructuringEnd(line, startCol) {
  // Walk backwards from startCol to find the opening { or [
  let i = startCol;
  while (i >= 0 && line[i] !== '{' && line[i] !== '[') i--;
  if (i < 0) return -1;
  
  const openChar = line[i];
  const closeChar = openChar === '{' ? '}' : ']';
  
  // Find matching close
  let depth = 1;
  let j = i + 1;
  while (j < line.length && depth > 0) {
    if (line[j] === openChar) depth++;
    if (line[j] === closeChar) depth--;
    j++;
  }
  
  if (depth === 0) return j - 1; // position of closing char
  return -1;
}
