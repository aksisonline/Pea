#!/usr/bin/python3
# Test helper: a minimal org.kde.StatusNotifierWatcher that inspects the registered item, then Activates it.
import dbus, dbus.service, dbus.mainloop.glib, sys
from gi.repository import GLib
dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
class W(dbus.service.Object):
    @dbus.service.method("org.kde.StatusNotifierWatcher", in_signature="s")
    def RegisterStatusNotifierItem(self, name):
        print("REGISTERED", name, flush=True)
        GLib.timeout_add(500, lambda: inspect(name))
def inspect(name):
    o = bus.get_object(name, "/StatusNotifierItem")
    p = dbus.Interface(o, "org.freedesktop.DBus.Properties")
    allp = p.GetAll("org.kde.StatusNotifierItem")
    px = allp["IconPixmap"][0]
    print("PROPS", allp["Id"], allp["Status"], allp["Title"], "pixmap", px[0], px[1], len(px[2]), flush=True)
    i = dbus.Interface(o, "org.kde.StatusNotifierItem")
    i.Activate(0, 0); print("ACTIVATED", flush=True)
    return False
name = dbus.service.BusName("org.kde.StatusNotifierWatcher", bus)
W(bus, "/StatusNotifierWatcher")
GLib.MainLoop().run()
