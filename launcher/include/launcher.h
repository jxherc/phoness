#pragma once
#include <stdint.h>

// see launcher/src/lib.rs
void launcher_start(const char *pairing_path, const char *ddi_dir, const char *runner_bundle, uint16_t rp_port, uint16_t port, const char *token);
void launcher_stop(void);
int32_t launcher_phase(void); // 0 off, 1 starting, 2 running, 3 failed
char *launcher_message(void);
char *launcher_apps(void); // json from the last start
void launcher_free(char *s);
