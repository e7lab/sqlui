; indents.scm for tree-sitter-bruno
; The bru format uses { } blocks (dictionary nodes) for indentation.

(dictionary) @indent.begin

["{" "}"] @indent.branch
["[" "]"] @indent.branch
