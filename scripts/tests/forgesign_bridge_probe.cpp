#include "ForgeSignBridge.h"
#include <algorithm>
#include <fstream>
#include <iostream>
#include <string>

// Audit helper: the password is read from a local file, never process arguments.
int main(int argc, char **argv) {
    char message[8192] = {}, bundleID[1024] = {}, version[1024] = {};
    int status = 1;
    if (argc == 4 && std::string(argv[1]) == "verify") {
        status = forgesign_verify_ipa(argv[2], argv[3], message, sizeof(message));
    } else if (argc == 10 && std::string(argv[1]) == "sign") {
        std::ifstream input(argv[4]);
        std::string password;
        if (!input) return 2;
        std::getline(input, password);
        if (input.bad()) return 2;
        status = forgesign_sign_ipa_profiles(argv[2], argv[3], password.c_str(), argv[5], argv[6],
            argv[7], argv[8], 0, 0, std::string(argv[9]) == "match", 0, message, sizeof(message),
            // 0, 0: keep extensions and skip the Files import, as the app's defaults do.
            bundleID, sizeof(bundleID), version, sizeof(version));
        std::fill(password.begin(), password.end(), '\0');
        // The app reads the same text as its signing log.
        static char engineLog[600000];
        forgesign_take_log(engineLog, sizeof(engineLog));
        std::cerr << "--- engine log ---\n" << engineLog << "--- end engine log ---\n";
    } else {
        std::cerr << "Usage: bridge-probe verify IPA TEMP\n"
                     "       bridge-probe sign IPA P12 PASSWORD_FILE PROFILE BUNDLE_ID OUTPUT TEMP match|profile\n";
        return 2;
    }
    std::cout << message << '\n';
    return status == 0 ? 0 : 1;
}
