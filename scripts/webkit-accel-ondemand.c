/* Generic WebKitGTK hardware-acceleration policy shim for XRING-O3.
 *
 * Wails v3 forces WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS. Under this
 * WebKitGTK 2.54.2 + Wayland/niri-anland stack, ALWAYS and NEVER both leave
 * the page layout viewport at 0x0, while ON_DEMAND initializes correctly.
 * Force every policy request to ON_DEMAND for session apps.
 *
 * This shim deliberately does not include or link any WebKit header/library:
 * it only interposes one exported symbol, so it is safe to preload into
 * non-WebKit processes and works with webkit2gtk 4.1 and 6.0 alike.
 *
 * Escape hatch: ZC_WEBKIT_ACCEL_POLICY=off disables the override.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>

typedef void (*webkit_set_policy_fn) (void *, int);

void
webkit_settings_set_hardware_acceleration_policy (void *settings, int policy)
{
  static webkit_set_policy_fn real;
  if (!real)
    real = (webkit_set_policy_fn) dlsym (RTLD_NEXT,
        "webkit_settings_set_hardware_acceleration_policy");
  if (!real)
    return;

  const char *off = getenv ("ZC_WEBKIT_ACCEL_POLICY");
  if (off && off[0] == 'o' && off[1] == 'f' && off[2] == 'f')
    {
      real (settings, policy);
      return;
    }

  /* 0 = WEBKIT_HARDWARE_ACCELERATION_POLICY_ON_DEMAND. */
  real (settings, 0);
}
