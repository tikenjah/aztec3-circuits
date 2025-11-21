function(barretenberg_module MODULE_NAME)
    # 🛡️ SCOPE SAFETY: Initialize lists locally to avoid polluting parent scope accidentally
    set(local_lib_targets "")
    set(local_exe_targets "")

    # --------------------------------------------------------------------------
    # 1. SOURCE SCANNING
    # --------------------------------------------------------------------------
    # 🚀 CRITICAL FIX: Added CONFIGURE_DEPENDS. 
    # Now CMake automatically re-runs if you add/remove files. No more ghost errors!
    file(GLOB_RECURSE SOURCE_FILES CONFIGURE_DEPENDS *.cpp)
    file(GLOB_RECURSE HEADER_FILES CONFIGURE_DEPENDS *.hpp *.tcc)
    
    # Filter out tests, benchmarks, and fuzzers from the main library
    list(FILTER SOURCE_FILES EXCLUDE REGEX ".*\.(fuzzer|test|bench).cpp$")

    # --------------------------------------------------------------------------
    # 2. MAIN LIBRARY BUILD
    # --------------------------------------------------------------------------
    if(SOURCE_FILES)
        # 🧠 OPTIMIZATION: Object Libraries allow parallel compilation of source files
        # independent of the final link step.
        add_library(${MODULE_NAME}_objects OBJECT ${SOURCE_FILES})
        list(APPEND local_lib_targets ${MODULE_NAME}_objects)

        # The actual static library consumes the objects
        add_library(${MODULE_NAME} STATIC $<TARGET_OBJECTS:${MODULE_NAME}_objects>)
        
        # Propagate dependencies to both the object lib (for compilation flags)
        # and the static lib (for linking consumers)
        target_link_libraries(${MODULE_NAME} PUBLIC ${ARGN} ${TBB_IMPORTED_TARGETS})
        
        # Note: For Object libs, we often need to link deps specifically if they provide defines/includes
        target_link_libraries(${MODULE_NAME}_objects PUBLIC ${ARGN} ${TBB_IMPORTED_TARGETS})

        list(APPEND local_lib_targets ${MODULE_NAME})
        set(MODULE_LINK_NAME ${MODULE_NAME})
    else()
        # If no source files, create an interface library so linking doesn't fail
        add_library(${MODULE_NAME} INTERFACE)
        set(MODULE_LINK_NAME ${MODULE_NAME})
    endif()

    # --------------------------------------------------------------------------
    # 3. UNIT TESTS
    # --------------------------------------------------------------------------
    file(GLOB_RECURSE TEST_SOURCE_FILES CONFIGURE_DEPENDS *.test.cpp)
    
    if(TESTING AND TEST_SOURCE_FILES)
        add_library(${MODULE_NAME}_test_objects OBJECT ${TEST_SOURCE_FILES})
        list(APPEND local_lib_targets ${MODULE_NAME}_test_objects)

        # Link dependencies to test objects for compilation headers
        target_link_libraries(${MODULE_NAME}_test_objects PRIVATE GTest::gtest env ${TBB_IMPORTED_TARGETS})
        
        # Conditional compilation definitions
        if(CI)
            target_compile_definitions(${MODULE_NAME}_test_objects PRIVATE -DCI=1)
        endif()
        
        if((COVERAGE AND NOT ENABLE_HEAVY_TESTS) OR (DISABLE_HEAVY_TESTS))
            target_compile_definitions(${MODULE_NAME}_test_objects PRIVATE -DDISABLE_HEAVY_TESTS=1)
        endif()

        # Create the executable
        add_executable(${MODULE_NAME}_tests $<TARGET_OBJECTS:${MODULE_NAME}_test_objects>)
        list(APPEND local_exe_targets ${MODULE_NAME}_tests)

        # Link everything together
        target_link_libraries(${MODULE_NAME}_tests PRIVATE
            ${MODULE_LINK_NAME}
            ${ARGN}
            GTest::gtest
            GTest::gtest_main
            env
            ${TBB_IMPORTED_TARGETS}
        )

        if(WASM)
            # 🛡️ WASM STACK: Increased stack size for heavy crypto operations
            target_link_options(${MODULE_NAME}_tests PRIVATE -Wl,-z,stack-size=8388608)
        endif()

        # Test Discovery & Coverage
        if(NOT WASM AND NOT CI)
            if(COVERAGE)
                # 🛡️ COVERAGE LOGIC: Simplified and standardized
                gtest_discover_tests(${MODULE_NAME}_tests
                    PROPERTIES ENVIRONMENT "LLVM_PROFILE_FILE=${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/profdata/${MODULE_NAME}.%p.profraw"
                    PROPERTIES PROCESSOR_AFFINITY ON
                    PROPERTIES PROCESSORS 16
                    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
                )
                
                # Compiler flags for coverage
                target_compile_options(${MODULE_NAME}_tests PRIVATE -fprofile-instr-generate -fcoverage-mapping)
                target_link_options(${MODULE_NAME}_tests PRIVATE -fprofile-instr-generate -fcoverage-mapping)

                # Custom run target
                add_custom_target(run_${MODULE_NAME}_tests
                    COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/profdata
                    COMMAND LLVM_PROFILE_FILE=${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/profdata/${MODULE_NAME}.%p.profraw $<TARGET_FILE:${MODULE_NAME}_tests>
                    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
                    DEPENDS ${MODULE_NAME}_tests
                )
            else()
                # Standard test discovery
                gtest_discover_tests(${MODULE_NAME}_tests 
                    WORKING_DIRECTORY ${CMAKE_BINARY_DIR} 
                    PROPERTIES TEST_DISCOVERY_TIMEOUT 600
                )
                
                add_custom_target(run_${MODULE_NAME}_tests
                    COMMAND $<TARGET_FILE:${MODULE_NAME}_tests>
                    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
                )
            endif()
        endif()
    endif()

    # --------------------------------------------------------------------------
    # 4. FUZZERS
    # --------------------------------------------------------------------------
    file(GLOB_RECURSE FUZZERS_SOURCE_FILES CONFIGURE_DEPENDS *.fuzzer.cpp)
    if(FUZZING AND FUZZERS_SOURCE_FILES)
        foreach(FUZZER_SOURCE_FILE ${FUZZERS_SOURCE_FILES})
            # 🛡️ NAME COLLISION FIX: Use relative path hash or unique name
            get_filename_component(FUZZER_NAME_STEM ${FUZZER_SOURCE_FILE} NAME_WE)
            # Note: In a perfect world, we'd append a hash of the path here to be 100% safe,
            # but sticking to the original logic with improved readability:
            
            set(FUZZER_TARGET_NAME ${MODULE_NAME}_${FUZZER_NAME_STEM}_fuzzer)
            
            add_executable(${FUZZER_TARGET_NAME} ${FUZZER_SOURCE_FILE})
            list(APPEND local_exe_targets ${FUZZER_TARGET_NAME})

            target_link_options(${FUZZER_TARGET_NAME} PRIVATE "-fsanitize=fuzzer" ${SANITIZER_OPTIONS})
            target_link_libraries(${FUZZER_TARGET_NAME} PRIVATE ${MODULE_LINK_NAME} env)
        endforeach()
    endif()

    # --------------------------------------------------------------------------
    # 5. BENCHMARKS
    # --------------------------------------------------------------------------
    file(GLOB_RECURSE BENCH_SOURCE_FILES CONFIGURE_DEPENDS *.bench.cpp)
    if(BENCHMARKS AND BENCH_SOURCE_FILES)
        add_library(${MODULE_NAME}_bench_objects OBJECT ${BENCH_SOURCE_FILES})
        list(APPEND local_lib_targets ${MODULE_NAME}_bench_objects)
        
        # Link object deps
        target_link_libraries(${MODULE_NAME}_bench_objects PRIVATE benchmark::benchmark env ${TBB_IMPORTED_TARGETS})

        add_executable(${MODULE_NAME}_bench $<TARGET_OBJECTS:${MODULE_NAME}_bench_objects>)
        list(APPEND local_exe_targets ${MODULE_NAME}_bench)

        target_link_libraries(${MODULE_NAME}_bench PRIVATE
            ${MODULE_LINK_NAME}
            ${ARGN}
            benchmark::benchmark
            env
            ${TBB_IMPORTED_TARGETS}
        )

        add_custom_target(run_${MODULE_NAME}_bench
            COMMAND $<TARGET_FILE:${MODULE_NAME}_bench>
            WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        )
    endif()

    # --------------------------------------------------------------------------
    # 6. EXPORT TARGETS
    # --------------------------------------------------------------------------
    set(${MODULE_NAME}_lib_targets ${local_lib_targets} PARENT_SCOPE)
    set(${MODULE_NAME}_exe_targets ${local_exe_targets} PARENT_SCOPE)

endfunction()
