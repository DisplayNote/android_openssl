import os

from conans import ConanFile
from conans import tools

class OpenSSLConan(ConanFile):

    settings = "os", "compiler", "build_type", "arch"
    description = "Package for OpenSSL libraries"
    url = "None"
    license = "None"
    generators = "qmake"
    keep_imports = True
    no_copy_source = True

    def getEnvs(self):
        pass

    def package_info(self):
        self.cpp_info.libs = tools.collect_libs(self)

    def package(self):
        source_path = os.path.join(str(self.settings.os), str(self.settings.build_type))
        self.copy("*.h", dst="include", src=os.path.join(source_path, "include"))
        self.copy("*.so", dst="lib", src=os.path.join(source_path, "lib"))
        self.copy("*.a", dst="lib", src=os.path.join(source_path, "lib"))

    def imports(self):
        dest = os.getenv("CONAN_IMPORT_DEST_PATH", "bin")
        self.copy("*", dst=dest, src="lib")
        self.copy("*", dst="lib", src="lib")
        self.copy("*", dst="include", src="include")

    def build(self):
        pass
