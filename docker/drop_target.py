#!/usr/bin/python3
# Test helper: a GTK4 window that accepts a file drop with MOVE and prints what it received.
import gi, sys
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Gdk, GLib
def on_drop(target, value, x, y):
    files = value.get_files()
    print("DROPPED", [f.get_uri() for f in files], flush=True)
    return True
def activate(app):
    w = Gtk.ApplicationWindow(application=app, title="drop-target")
    w.set_default_size(200, 200)
    lbl = Gtk.Label(label="DROP HERE"); w.set_child(lbl)
    t = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.MOVE | Gdk.DragAction.COPY)
    t.connect("drop", on_drop)
    lbl.add_controller(t)
    w.present()
app = Gtk.Application(application_id="test.droptarget"); app.connect("activate", activate); app.run([])
