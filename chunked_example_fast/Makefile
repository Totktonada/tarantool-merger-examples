default: test

.PHONY: start
start: clean
	mkdir -p storage_1
	mkdir -p storage_2
	./storage_1.lua
	./storage_2.lua

.PHONY: stop
stop:
	test -f storage_1.pid && PID=$$(cat storage_1.pid) && kill $$PID && \
		while kill -0 $$PID 2>/dev/null; do sleep 0.1; done || true
	test -f storage_2.pid && PID=$$(cat storage_2.pid) && kill $$PID && \
		while kill -0 $$PID 2>/dev/null; do sleep 0.1; done || true

.PHONY: test
test:
	$(MAKE) start
	./frontend.lua
	$(MAKE) stop

.PHONY: clean
clean:
	rm storage_[12]/*.{xlog,snap} || true
	rmdir storage_[12] || true
	rm storage_[12].{log,pid,instance.uuid,cluster.uuid} || true
	rm *.{xlog,snap} || true
