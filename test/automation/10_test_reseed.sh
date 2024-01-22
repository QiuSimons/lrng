#!/bin/bash
#
# Test for DRNG reseed operation
#
# Copyright (C) 2021, Stephan Mueller <smueller@chronox.de>
#
# License: see LICENSE file in root directory
#
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, ALL OF
# WHICH ARE HEREBY DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
# BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
# USE OF THIS SOFTWARE, EVEN IF NOT ADVISED OF THE POSSIBILITY OF SUCH
# DAMAGE.
#

. $(dirname $0)/libtest.sh

TESTNAME="DRNG reseed"

create_irqs()
{
	local i=0
	while [ $i -lt 256 ]
	do
		echo "Test message - ignore" >&2
		i=$(($i+1))
	done

	dd if=/bin/bash of=$HOMEDIR/reseed.tmp oflag=sync
	rm -f $HOMEDIR/reseed.tmp
	sync

	dd if=/dev/urandom of=/dev/null bs=32 count=1
}

cause_reseed()
{
	echo > /dev/random
	dd if=/dev/urandom of=/dev/null bs=32 count=1 > /dev/null 2>&1
}

# Drain DRNG and check that getrandom blocks
drain_drng2()
{
	local data=0
	local max_attempts=30
	local fetch=32

	while [ $max_attempts -gt 0 ]
	do
		echo > /dev/random
		dd if=/dev/urandom of=/dev/null bs=$fetch count=1 > /dev/null 2>&1

		max_attempts=$(($max_attempts-1))

		if (cat /proc/lrng_type  | grep -q "LRNG fully seeded: false")
		then
			break
		fi
	done

	$(dirname $0)/syscall_test -s > /dev/null 2>&1
	local ret=$?

	if [ $max_attempts -le 0 ]
	then
		echo_fail "$TESTNAME: LRNG reports it is not fully seeded after draining and reseeding"
		exit
	fi

	if [ $ret -eq 11 ]
	then
		echo_pass "$TESTNAME: LRNG blocked reading of blocking interface"
	else
		echo_fail "$TESTNAME: LRNG did not block reading of blocking interface - error code $ret"
	fi
}

# Drain DRNG and check that LRNG turns to non-operational
drain_drng1()
{
	local data=0
	local max_attempts=30
	local fetch=32

	# Disable the in-kernel hwrng thread
	echo 0 > /sys/module/rng_core/parameters/current_quality

	while [ $max_attempts -gt 0 ]
	do
		echo > /dev/random
		data=$(dd if=/dev/urandom of=/dev/null bs=$fetch count=1 2>&1 | grep "bytes copied" | cut -d " " -f 1)

		max_attempts=$(($max_attempts-1))

		if (dmesg | grep "LRNG set to non-operational")
		then
			break
		fi
	done

	local state=$(cat /proc/lrng_type)
	$(dirname $0)/syscall_test -s > /dev/null 2>&1
	local ret=$?

	if [ $max_attempts -le 0 ]
	then
		echo_fail "$TESTNAME: LRNG reports it is fully seeded after draining and reseeding"
		exit
	else
		echo_pass "$TESTNAME: LRNG reports it is not seeded any more after draining and reseeding"
	fi

	if [ $data -eq $fetch ]
	then
		echo_pass "$TESTNAME: LRNG does not block reading /dev/urandom when entering non-operational"
	else
		echo_fail "$TESTNAME: LRNG blocked reading /dev/urandom when entering non-operational"
	fi

	if (echo $state  | grep -q "LRNG fully seeded: false")
	then
		echo_pass "$TESTNAME: LRNG proc status indicates not fully seeded after draining and reseeding"
	else
		echo_fail "$TESTNAME: LRNG proc status indicates fully seeded after draining and reseeding"
	fi

	if [ $ret -eq 11 ]
	then
		echo_pass "$TESTNAME: LRNG blocked reading of blocking interface"
	else
		echo_fail "$TESTNAME: LRNG did not block reading of blocking interface - error code $ret"
	fi
}

check_reseed()
{
	local lastseed=$(dmesg | grep "lrng_drng: DRNG fully seeded" | tail -n 1)
	local oldop=$(dmesg | grep "LRNG fully operational")
	if [ -z "$oldop" ]
	then
		oldop=""
	fi

	#
	# 1. Check that LRNG is NOT reseeded or re-set to fully operational
	#    since we require two reseeds
	#

	cause_reseed

	local op=$(dmesg | grep "LRNG fully operational" | tail -n 1)
	local newseed=$(dmesg | grep "lrng_drng: DRNG fully seeded" | tail -n 1)
	if [ -z "$op" ]
	then
		op=""
	fi

	if [ "$op" = "$oldop" -a "$lastseed" = "$newseed" ]
	then
		echo_pass "$TESTNAME: LRNG is not re-initialized after one reseed"
	else
		echo_fail "$TESTNAME: LRNG is re-initialized for after one reseed"
	fi

	#
	# 2. Check that LRNG is reseeded and re-set to fully operational after
	#    second generate operation
	#

	drain_drng1

	create_irqs

	op=$(dmesg | grep "LRNG fully operational" | tail -n 1)
	newseed=$(dmesg | grep "lrng_drng_mgr: regular DRNG fully seeded" | tail -n 1)
	if [ -z "$op" ]
	then
		op=""
	fi

	if [ "$op" = "$oldop" ]
	then
		echo_fail "$TESTNAME: LRNG is not re-initialized to operational after new reseed with full entropy"
	else
		echo_pass "$TESTNAME: LRNG is re-initialized to operational after new reseed with full entropy"
	fi

	if [ "$lastseed" = "$newseed" ]
	then
		echo_fail "$TESTNAME: LRNG is not re-seeded after new reseed with full entropy"
	else
		echo_pass "$TESTNAME: LRNG is re-seeded after new reseed with full entropy"
	fi

	drain_drng2
}

exec_test1()
{
	$(check_kernel_config "CONFIG_LRNG_RUNTIME_FORCE_SEEDING_DISABLE=y")
	if [ $? -ne 0 ]
	then
		echo_deact "$TESTNAME: tests skipped"
		exit
	fi

	check_reseed
}

exec_test2()
{
	if (dmesg | grep "Initial DRNG initialized without seeding")
	then
		echo_pass "$TESTNAME: Initial seeding not performed due to forced seeding"
		return
	fi

	if (dmesg | grep "Initial DRNG initialized triggering first seeding")
	then
		echo_pass "$TESTNAME: Initial seeding performed"
	else
		echo_fail "$TESTNAME: Initial seeding not performed"
	fi
}

#
# Test gathering seed from ES
#
exec_test3()
{
	local locdir=$(dirname $0)
	local size
	local data

	# Request 1 byte from kernel
	# Expected: EINVAL as buffer is too small
	$locdir/syscall_test -b 1 -y > /dev/null 2>&1
	if [ $? -ne 22 ]
	then
		echo_fail "lrng_get_seed does not indicate that the buffer is too small - return code $?"
	fi

	# Request 8 bytes from char kernel
	# Expected: EMSGSIZE as error, but also an uint64_t holding a buffer size
	size=$($locdir/syscall_test -b 8 -y 2>/dev/null)
	if [ $? -ne 90 ]
	then
		echo_fail "lrng_get_seed does not indicate that the buffer is too small"
	fi
	if [ $size -gt 500 ]
	then
		echo_fail "lrng_get_seed specifies a buffer that is too large: $size"
	else
		echo_pass "lrng_get_seed specifies reasonable buffer size: $size"
	fi

	create_irqs

	# Request the seed data with potentially oversampling
	# Expected: no error, filled buffer
	data=$($locdir/syscall_test -b $size -y 2>/dev/null)
	if [ $? -ne 0 ]
	then
		echo_fail "lrng_get_seed returned an error: $?"
	else
		echo_pass "lrng_get_seed returned data"
	fi

	create_irqs

	# Request the seed data without oversampling
	# Expected: no error, filled buffer
	data=$($locdir/syscall_test -z $size -y 2>/dev/null)
	if [ $? -ne 0 ]
	then
		echo_fail "lrng_get_seed returned an error: $?"
	else
		echo_pass "lrng_get_seed returned data"
	fi
}

$(in_hypervisor)
if [ $? -eq 1 ]
then
	case $(read_cmd) in
		"test1")
			exec_test1
			;;
		"test2")
			exec_test2
			;;
		"test3")
			exec_test3
			;;
		*)
			echo_fail "Test $1 not found"
			;;
	esac
else
	$(check_kernel_config "CONFIG_LRNG_IRQ=y")
	if [ $? -ne 0 ]
	then
		echo_deact "$TESTNAME: tests skipped"
		exit
	fi

	$(check_kernel_config "LRNG_RUNTIME_MAX_WO_RESEED_CONFIG=y")
	if [ $? -ne 0 ]
	then
		echo_deact "$TESTNAME: tests skipped"
		exit
	fi

	gcc -DTEST -Wall -pedantic -Wextra -o syscall_test ../syscall_test.c
	if [ $? -ne 0 ]
	then
		echo_fail "$TESTNAME: syscall_test application cannot be compiled"
		exit
	fi

	#
	# Validating LRNG_DRNG_MAX_WITHOUT_RESEED enforced after two reseeds
	#
	write_cmd "test1"
	execvirt $(full_scriptname $0) "lrng_drng_mgr.max_wo_reseed=2 lrng_es_cpu.cpu_entropy=8 lrng_es_jent.jent_entropy=16 lrng_drng_mgr.force_seeding=0"

	#
	# Verify first seed operation during initialization
	#
	write_cmd "test2"
	execvirt $(full_scriptname $0)

	#
	# Verify gathering of seed data
	#
	write_cmd "test3"
	execvirt $(full_scriptname $0) "lrng_es_cpu.cpu_entropy=8 lrng_es_jent.jent_entropy=16"

	rm -f syscall_test
fi
