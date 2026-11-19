# drydock_check_runs(SOURCE VAR): check_c_source_runs, but only where tests/lib/exec-arch.sh's can_exec says this host
# executes DRYDOCK_TEST_ARCH; elsewhere (x86_64 on Apple Silicon) nothing runs and VAR is false.
include(CheckCSourceRuns)
set(_drydock_check_runs_root "${CMAKE_CURRENT_LIST_DIR}/..")
function(drydock_check_runs src var)
  if(APPLE)
    execute_process(COMMAND sh -c ". \"$1\" && can_exec \"$2\"" sh
        "${_drydock_check_runs_root}/tests/lib/exec-arch.sh" "${DRYDOCK_TEST_ARCH}"
      RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
    if(NOT rc EQUAL 0)
      message(STATUS "Performing Test ${var} - not run: this host cannot execute ${DRYDOCK_TEST_ARCH}")
      unset(${var} CACHE)
      set(${var} FALSE PARENT_SCOPE)
      return()
    endif()
  endif()
  check_c_source_runs("${src}" ${var})
endfunction()
