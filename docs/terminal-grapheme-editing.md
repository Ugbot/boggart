# Composer grapheme editing

The TUI input widget and Studio AgentView composer now move, backspace and
forward-delete by the native Unicode16 effective cluster iterator. Accents,
emoji ZWJ sequences, modifiers, regional-indicator pairs, selectors and Indic
conjuncts stay whole. AgentView also has a forward-delete path, including joining
the next physical line and deleting its keyboard selection.

`sys.cell_next(text, byte_position[, exclusive_end])` returns the next 1-based
byte gap without allocating a substring. The range must satisfy
`1 <= position <= end <= #text + 1`; an empty range returns its position.
The binding shares `btunicode_text_next`, including its retained-cell cap and
source-byte consumption rules. It does not validate that an arbitrary starting
position is already a cluster boundary.

`lua/grapheme.lua` builds boundary arrays using that iterator. Physical controls
(especially newlines and tabs) are separate editing units, so the renderer's
plain-text policy of ignoring a control does not swallow a composer's line
break. Four short-text arrays are cached; texts over 64KB are not retained.
Each printable span is scanned without repeatedly allocating its suffix.

The public cursor conventions are preserved: `Input.cursor` is a zero-based
codepoint offset, its `cx` is a one-based codepoint position, and AgentView `cx`
is a one-based byte position. Voice `replace_span` remains an exact codepoint
span operation; its resulting caret is snapped to a complete cluster.

The modal composer adapters expose virtual **grapheme columns** to the shared
grammar. That makes counted commands, replace, paste and append operate on whole
units without interpreting a byte or scalar inside an emoji as a new character.
The optional `adapter:pattern_units(pattern)` hook lets Unicode search and
prompt backspace use those same units. DocView's default pattern policy remains
unchanged. Undo snapshots retain each surface's existing public offset fields.

TUI styled runs inherit the cluster head's style. Wrapped rows and cursor display
use native cell width for whole clusters, so an emoji does not split across rows
or consume a scalar-summed four columns in a two-column cell profile. A caret
after a completely full row gets a continuation row, preventing the frame from
clamping it onto the final emoji's cell.

Tests are `tests/grapheme_edit.lua` (native range validation, editing, input
events, modal counts/paste/append/search, controls and wrapped rows), the composer
cases in `tests/studio.lua`, and existing input/editor tests. Unicode16 profile
behavior remains authoritative; this change does not add paragraph bidi,
Unicode word-boundary navigation, normalization or Unicode17 properties.

The normal full checkpoint passes 162/162 tests. Focused normal and sanitizer
checks cover both modal adapters and the existing shared grammar; the actual
Studio replay also checks cluster selection and drawing. General CLI external
terminal width policy, bidi and the full BMUX performance gates remain open.
