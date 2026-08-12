# parity.cmake -- the CLI and the GUI are one engine, and this proves it.
#
# Run with `ninja core-parity`. Not a ctest: it starts boggart-studio, which
# needs a window server, and CI has none.
#
# The comparison is asymmetric on purpose. The studio may register tools that
# only mean something with a window -- drawing a panel is not a thing a
# terminal can do -- so those are named here and allowed. Everything else must
# match, and a capability present in the CLI but missing from the GUI fails
# regardless, because that is the direction that makes the window a lesser
# product rather than a different one.
#
# Two groups of studio-only tools:
#   1. The panel-drawing tools, which need a window.
#   2. The swarm orchestration tools (spawn/await/send/publish/subscribe/inbox/
#      threads). The CLI registers these only in `boggart swarm`, a distinct
#      mode; the studio assumes swarm mode by default (the owner's directive:
#      "if you're using the UI you're doing the kind of multi-agent work swarm
#      mode is for"), so it offers them from every chat -- the chat turn is
#      coordinator actor 0 and the studio pumps the scheduler. They are the same
#      tools as the CLI's swarm mode, so this is a difference in which surface
#      offers them by default, not a capability the CLI lacks.
set(GUI_ONLY_TOOLS "draw_panel;list_panels;read_panel;delete_panel;spawn;await;send;publish;subscribe;inbox;threads")

if(NOT DEFINED CLI OR NOT DEFINED GUI OR NOT DEFINED FP OR NOT DEFINED FPGUI)
  message(FATAL_ERROR "parity.cmake needs -DCLI= -DGUI= -DFP= -DFPGUI=")
endif()

# Separate throwaway homes, so neither run inherits the other's database or a
# developer's credentials. The fingerprint reports paths relative to the data
# directory precisely so these can differ.
set(H1 "${CMAKE_CURRENT_BINARY_DIR}/parity-home-cli")
set(H2 "${CMAKE_CURRENT_BINARY_DIR}/parity-home-gui")
file(MAKE_DIRECTORY "${H1}" "${H2}")

execute_process(COMMAND ${CMAKE_COMMAND} -E env HOME=${H1} BOGGART_HOME=${H1}/.boggart
    ${CLI} --eval ${FP}
  OUTPUT_VARIABLE cli_out ERROR_VARIABLE cli_err RESULT_VARIABLE cli_rc)
if(NOT cli_rc EQUAL 0)
  message(FATAL_ERROR "the CLI fingerprint failed (${cli_rc}):\n${cli_err}${cli_out}")
endif()

execute_process(COMMAND ${CMAKE_COMMAND} -E env HOME=${H2} BOGGART_HOME=${H2}/.boggart
    BOGGART_FINGERPRINT=${FP} BOGGART_STUDIO_SCRIPT=${FPGUI} ${GUI} .
  OUTPUT_VARIABLE gui_out ERROR_VARIABLE gui_err RESULT_VARIABLE gui_rc)
if(NOT gui_rc EQUAL 0)
  message(FATAL_ERROR "the studio fingerprint failed (${gui_rc}):\n${gui_err}${gui_out}")
endif()

# The studio prints editor chatter before the fingerprint; keep only key=value
# lines, which is what the fingerprint emits and nothing else does.
function(parse blob out_keys out_map)
  string(REPLACE "\n" ";" lines "${blob}")
  set(keys "")
  foreach(line IN LISTS lines)
    string(STRIP "${line}" line)
    if(line MATCHES "^([a-z_]+)=(.*)$")
      list(APPEND keys "${CMAKE_MATCH_1}")
      set(v_${CMAKE_MATCH_1} "${CMAKE_MATCH_2}" PARENT_SCOPE)
    endif()
  endforeach()
  set(${out_keys} "${keys}" PARENT_SCOPE)
  set(${out_map} "" PARENT_SCOPE)
endfunction()

parse("${cli_out}" cli_keys _u)
foreach(k IN LISTS cli_keys)
  set(cli_${k} "${v_${k}}")
endforeach()
parse("${gui_out}" gui_keys _u)
foreach(k IN LISTS gui_keys)
  set(gui_${k} "${v_${k}}")
endforeach()

if(cli_keys STREQUAL "")
  message(FATAL_ERROR "the CLI produced no fingerprint at all:\n${cli_out}")
endif()
if(gui_keys STREQUAL "")
  message(FATAL_ERROR "the studio produced no fingerprint at all:\n${gui_out}")
endif()

set(problems "")
foreach(k IN LISTS cli_keys)
  if(NOT DEFINED gui_${k})
    list(APPEND problems "  ${k}: present in the CLI, absent from the studio")
  elseif(k STREQUAL "tools")
    # Every CLI tool must exist in the GUI; the GUI may add window-only ones.
    string(REPLACE "," ";" cli_tools "${cli_${k}}")
    string(REPLACE "," ";" gui_tools "${gui_${k}}")
    foreach(t IN LISTS cli_tools)
      if(NOT t IN_LIST gui_tools)
        list(APPEND problems "  tool '${t}' exists in the CLI but not the studio")
      endif()
    endforeach()
    foreach(t IN LISTS gui_tools)
      if(NOT t IN_LIST cli_tools AND NOT t IN_LIST GUI_ONLY_TOOLS)
        list(APPEND problems
          "  tool '${t}' exists only in the studio and is not a declared window-only tool")
      endif()
    endforeach()
  elseif(NOT cli_${k} STREQUAL gui_${k})
    list(APPEND problems "  ${k}:\n      cli: ${cli_${k}}\n      gui: ${gui_${k}}")
  endif()
endforeach()
foreach(k IN LISTS gui_keys)
  if(NOT DEFINED cli_${k})
    list(APPEND problems "  ${k}: present in the studio, absent from the CLI")
  endif()
endforeach()

if(problems)
  string(REPLACE ";" "\n" problems "${problems}")
  message(FATAL_ERROR
    "the CLI and the studio have drifted apart:\n${problems}\n\n"
    "If a difference is deliberate, it belongs in GUI_ONLY_TOOLS in "
    "tools/parity.cmake with a reason, not left to be discovered.")
endif()

list(LENGTH cli_keys n)
message(STATUS "core parity: ${n} fields identical across the CLI and the studio")
