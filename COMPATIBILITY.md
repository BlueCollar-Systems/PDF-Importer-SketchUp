# Ruby 2.2 Compatibility Guide

All Ruby code in this extension **must** run on Ruby 2.2.4, which ships with
SketchUp Make 2017. This document lists constructs that are NOT available in
Ruby 2.2 and the safe alternatives to use instead.

---

## Constructs to Avoid

| Construct | Introduced | Safe Alternative (Ruby 2.2) |
|---|---|---|
| `Array#sum` | 2.4 | `array.inject(0, :+)` |
| `Hash#transform_keys` | 2.5 | `Hash[hash.map { \|k, v\| [new_key(k), v] }]` |
| `Hash#transform_values` | 2.4 | `Hash[hash.map { \|k, v\| [k, new_val(v)] }]` |
| `&.` (safe navigation operator) | 2.3 | `obj && obj.method` |
| `Object#then` / `Object#yield_self` | 2.5 / 2.6 | Use a local variable or explicit block |
| `Enumerable#filter` | 2.6 | `Enumerable#select` |
| `Enumerable#filter_map` | 2.7 | `.select { ... }.map { ... }` |
| `Enumerable#tally` | 2.7 | `each_with_object(Hash.new(0)) { \|v, h\| h[v] += 1 }` |
| `Integer#digits` | 2.4 | `n.to_s.chars.map(&:to_i).reverse` |
| `String#match?` | 2.4 | `!!(string =~ regex)` |
| `Hash#dig` / `Array#dig` | 2.3 | Chain `[]` with nil checks |
| `Kernel#pp` (auto-require) | 2.5 | `require 'pp'; pp obj` |
| Keyword argument separation (hash/kwargs) | 2.7 warning, 3.0 enforced | Keep Ruby 2.2 calling conventions |
| `rescue` inside blocks without `begin`/`end` | 2.5 | Wrap with explicit `begin`/`end` |
| Heredoc with `<<~` (squiggly) | 2.3 | Use `<<-` and manually manage indentation |
| `#frozen_string_literal: true` pragma | 2.3 | Works on 2.3+; do NOT rely on it for 2.2 |

## Frozen String Literal Pragma

The `# frozen_string_literal: true` magic comment is **recognized starting in
Ruby 2.3**. On Ruby 2.2 the comment is silently ignored, so it will not cause
errors, but it also will not freeze strings. Do not write code that depends on
string immutability enforced by this pragma.

## General Rules

1. Before merging, CI runs `ruby -c` on every `.rb` file under Ruby 2.2, 2.7,
   and 3.2 to catch syntax issues early.
2. Never use features listed above without a version guard or polyfill.
3. When in doubt, test with `docker run --rm ruby:2.2 ruby -c yourfile.rb`.
