# Author: wilbur
# Version: 1.10
# Date: 2026-06-03
# Description: CMake build for rawViewer project；新增 macOS Metal-backed 图片分析源、metadata reader、ImageIO JPG writer 和 framework 链接；为 OBJCXX 目标开启 ARC，注册 objcRuntimeTests，并为测试目标启用 Metal diagnostics；同步新增 jpgWriter 与 photoMetadataReader 源文件

cmake_minimum_required(VERSION 3.16)
project(rawViewer LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
option(RAWVIEWER_BUILD_TESTS "Build rawViewer lightweight tests" OFF)

# --- 3rdParty root ---
set(THIRD_PARTY_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../3rdPart)

# --- yaml-cpp (static) ---
add_library(yaml-cpp STATIC IMPORTED)
set_target_properties(yaml-cpp PROPERTIES
    IMPORTED_LOCATION ${THIRD_PARTY_DIR}/yaml/lib/libyaml-cpp.a
    INTERFACE_INCLUDE_DIRECTORIES ${THIRD_PARTY_DIR}/yaml/include
)

# --- nlohmann/json (header-only) ---
add_library(nlohmann_json INTERFACE)
target_include_directories(nlohmann_json INTERFACE ${THIRD_PARTY_DIR}/json)

# --- LibRaw (static) ---
add_library(libraw STATIC IMPORTED)
set_target_properties(libraw PROPERTIES
    IMPORTED_LOCATION ${THIRD_PARTY_DIR}/libraw/lib/libraw.a
    INTERFACE_INCLUDE_DIRECTORIES ${THIRD_PARTY_DIR}/libraw/include
)

# --- OpenCV (manual static import, avoid broken find_package) ---
set(OPENCV_DIR ${THIRD_PARTY_DIR}/opencv)

# 3rdparty static libs from OpenCV
set(OPENCV_3RDPARTY_LIBS
    ${OPENCV_DIR}/lib/opencv4/3rdparty/liblibjpeg-turbo.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/liblibtiff.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/liblibwebp.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/liblibpng.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/liblibopenjp2.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/libIlmImf.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/libzlib.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/libittnotify.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/libtegra_hal.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/libkleidicv_hal.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/libkleidicv_thread.a
    ${OPENCV_DIR}/lib/opencv4/3rdparty/libkleidicv.a
)

add_library(opencv_core STATIC IMPORTED)
set_target_properties(opencv_core PROPERTIES
    IMPORTED_LOCATION ${OPENCV_DIR}/lib/libopencv_core.a
    INTERFACE_INCLUDE_DIRECTORIES ${OPENCV_DIR}/include/opencv4
)

add_library(opencv_imgproc STATIC IMPORTED)
set_target_properties(opencv_imgproc PROPERTIES
    IMPORTED_LOCATION ${OPENCV_DIR}/lib/libopencv_imgproc.a
)

add_library(opencv_imgcodecs STATIC IMPORTED)
set_target_properties(opencv_imgcodecs PROPERTIES
    IMPORTED_LOCATION ${OPENCV_DIR}/lib/libopencv_imgcodecs.a
)

# --- Project sources ---
set(SOURCES
    src/appRunner.cpp
    src/configLoader.cpp
    src/fileScanner.cpp
    src/gpuSupport.mm
    src/imageAnalyzer.cpp
    src/jsonManager.cpp
    src/jpgWriter.mm
    src/macImageAnalyzer.mm
    src/photoMetadataReader.mm
    src/rawConverter.cpp
    src/rawJpgMat.cpp
    src/resumePlanner.cpp
    src/taskState.cpp
    src/threadPool.cpp
    main.cpp
)

add_executable(rawViewer ${SOURCES})

set(GPU_IMAGE_KERNELS ${CMAKE_CURRENT_SOURCE_DIR}/src/gpuImageKernels.metal)
add_custom_command(TARGET rawViewer POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${GPU_IMAGE_KERNELS}
        $<TARGET_FILE_DIR:rawViewer>/gpuImageKernels.metal
)

target_compile_options(rawViewer PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)

target_include_directories(rawViewer PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(rawViewer PRIVATE
    opencv_imgcodecs
    opencv_imgproc
    opencv_core
    ${OPENCV_3RDPARTY_LIBS}
    yaml-cpp
    nlohmann_json
    libraw
)

# macOS frameworks needed by OpenCV
if(APPLE)
    find_library(FOUNDATION_LIBRARY Foundation)
    find_library(APPKIT_LIBRARY AppKit)
    find_library(IMAGEIO_LIBRARY ImageIO)
    find_library(COREGRAPHICS_LIBRARY CoreGraphics)
    find_library(COREIMAGE_LIBRARY CoreImage)
    find_library(CORESERVICES_LIBRARY CoreServices)
    find_library(METAL_LIBRARY Metal)
    find_library(MPS_LIBRARY MetalPerformanceShaders)
    find_library(OPENCL_LIBRARY OpenCL)
    find_library(ACCELERATE_LIBRARY Accelerate)
    target_link_libraries(rawViewer PRIVATE
        ${FOUNDATION_LIBRARY}
        ${APPKIT_LIBRARY}
        ${IMAGEIO_LIBRARY}
        ${COREGRAPHICS_LIBRARY}
        ${COREIMAGE_LIBRARY}
        ${CORESERVICES_LIBRARY}
        ${METAL_LIBRARY}
        ${MPS_LIBRARY}
        ${OPENCL_LIBRARY}
        ${ACCELERATE_LIBRARY}
    )
endif()

if(RAWVIEWER_BUILD_TESTS)
    add_executable(rawViewerTests
        src/rawJpgMat.cpp
        src/taskState.cpp
        tests/testMain.cpp
        tests/summaryCountsTests.cpp
        tests/rawJpgMatTests.cpp
        tests/perfTimerTests.cpp
    )

    target_include_directories(rawViewerTests PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/tests
    )

    target_link_libraries(rawViewerTests PRIVATE
        opencv_imgproc
        opencv_core
        ${OPENCV_3RDPARTY_LIBS}
    )

    if(APPLE)
        target_link_libraries(rawViewerTests PRIVATE
            ${FOUNDATION_LIBRARY}
            ${APPKIT_LIBRARY}
            ${COREGRAPHICS_LIBRARY}
            ${COREIMAGE_LIBRARY}
            ${METAL_LIBRARY}
            ${MPS_LIBRARY}
            ${OPENCL_LIBRARY}
            ${ACCELERATE_LIBRARY}
        )
    endif()
endif()
