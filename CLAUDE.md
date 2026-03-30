# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Formatting Standards  <!-- omit in toc -->

### Markdown Rules  <!-- omit in toc -->
- Never use --- as chapter or section separator in markdown files
- Never use icons or emojis in markdown generated files (no emojis at all)
- Use __ for bold text, not **
- Align column separators in markdown tables (right-most separator can remain unaligned)
- Mark all headers below the top-most chapter header with "  <!-- omit in toc -->" (2 spaces before comment)
  - Top-most header (document title): NO marker
  - All subsequent headers (##, ###, etc.): Add marker

### Code and Console Output  <!-- omit in toc -->
- Never use icons or emojis in generated code, log output, or console output (no emojis at all)

### Response Style  <!-- omit in toc -->
- Short, precise, accurate answers only
- Never hallucinate or make guesses
- Never state implicit assumptions
- No fluff or unnecessary elaboration
- Base all answers on verified facts only
- Never make vague or imprecise statements
- Avoid unvalidatable claims (e.g., "production quality", "enterprise-grade", "robust", "scalable")
- Use only validatable, measurable statements with specific criteria
- Every statement must be verifiable through code inspection, testing, measurable metrics or documentation

### Audience  <!-- omit in toc -->
- Highly trained senior software engineers
- Embedded software real-time development expertise
- Minimum Master's degree education level
- Skip basic explanations
- Use domain-specific terminology without definition
- Focus on technical depth and implementation details

### Tool Preferences  <!-- omit in toc -->
- When suggesting bash commands with text editors, use vi instead of nano
- Never add "Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>" to git commit messages

## Build and Development Commands  <!-- omit in toc -->

### Pre-commit  <!-- omit in toc -->

```bash
pre-commit run           # staged files only
pre-commit run --all     # all files
```

Hooks: trailing-whitespace, end-of-file-fixer, check-yaml, check-added-large-files, black (line-length 120), autoflake. Excludes `hil_dupe/`.

## Architecture  <!-- omit in toc -->

## Code Standards  <!-- omit in toc -->

- Black formatter, line-length 120
- Type hints (PEP 484) required for new code (Python Enhancemets Proposals)
- Autoflake for unused import cleanup
- 97% minimum unit test coverage, 100% target (condition and branch)
- SonarCloud PR minimum: 80% coverage
- PEP 8 (Python style guide) (Python Enhancement Proposals)

## Branch Naming  <!-- omit in toc -->

- Features: `feature/<initials>/<name>`
- Work items: `<three-user-initials>/wi<ticket_number>_<description>`
- Main development branch: `main` (PR target)
- Release branch: `main`
