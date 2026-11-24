# Injected into chiaki-ng's top-level project() via CMAKE_PROJECT_INCLUDE.
# chiaki's lib/CMakeLists.txt calls pkg_search_module() for libevent without
# loading FindPkgConfig in that scope when json-c/miniupnpc are built in-tree.
find_package(PkgConfig REQUIRED)
