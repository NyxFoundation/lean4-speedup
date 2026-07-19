import gdb, time
gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("run &")
time.sleep(0.70)
gdb.execute("interrupt")
time.sleep(0.4)
gdb.execute("thread apply all bt 40")
gdb.execute("kill")
