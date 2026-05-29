# Author: wilbur
# Version: 1.0
# Date: 2026-05-29
# Description: CMake build for rawViewer project

cmake_minimum_required(VERSION 3.16)
project(rawViewer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

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
    src/imageAnalyzer.cpp
    src/jsonManager.cpp
    src/rawConverter.cpp
    src/resumePlanner.cpp
    src/taskState.cpp
    src/threadPool.cpp
    main.cpp
)

add_executable(rawViewer ${SOURCES})

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
    find_library(OPENCL_LIBRARY OpenCL)
    find_library(ACCELERATE_LIBRARY Accelerate)
    target_link_libraries(rawViewer PRIVATE
        ${FOUNDATION_LIBRARY}
        ${APPKIT_LIBRARY}
        ${OPENCL_LIBRARY}
        ${ACCELERATE_LIBRARY}
    )
endif()
