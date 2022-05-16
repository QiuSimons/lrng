#!/bin/bash
#
# Test for CPU RNG operation
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

SYSFS="/sys/module/lrng_es_cpu/parameters/cpu_entropy"

verify_entropyrate()
{
	local expected_rate=$1

	# Force reseed
	echo >/dev/random; dd if=/dev/random of=/dev/null bs=32 count=1

	local found=$(dmesg | grep "lrng_es_cpu: obtained" | tail -n 1 | sed 's/^.* obtained \([0-9]\+\) bits.*$/\1/')

	if [ -z "$found" ]
	then
		echo_deact "CPU RNG: Cannot obtain entropy rate from kernel log"
	else
		if [ $expected_rate -eq $found ]
		then
			echo_pass "CPU RNG: Verified entropy rate $expected_rate with kernel log"
		else
			echo_fail "CPU RNG: Entropy rate $expected_rate does not match with kernel log: $found"
		fi
	fi

	local found=$(cat $SYSFS)
	if [ -z "$found" ]
	then
		echo_deact "CPU RNG: Cannot obtain entropy rate from SysFS file $SYSFS"

	# The SysFS file is not reset in case of an overflow
	elif [ $found -le 256 ]
	then
		if [ $expected_rate -eq $found ]
		then
			echo_pass "CPU RNG: Verified entropy rate $expected_rate with SysFS file $SYSFS"
		else
			echo_fail "CPU RNG: Entropy rate $expected_rate does not match with SysFS: $found"
		fi
	fi
}

verify_entropyrate_boot()
{
	local rate=8

	for i in $(cat /proc/cmdline)
	do
		if (echo $i | grep -q cpu)
		then
			rate=$(echo $i | cut -d"=" -f 2)
		fi
	done

	verify_entropyrate $rate
}

verify_set_entropyrate()
{
	local rate=$1

	echo $rate > $SYSFS
	verify_entropyrate $rate
}

verify_set_entropyrate_overflow()
{
	local rate=$1

	echo $rate > $SYSFS
	verify_entropyrate 256
}

verify_cpu()
{
	# Force reseed
	echo >/dev/random; dd if=/dev/random of=/dev/null bs=32 count=1

	if (dmesg | grep -q "lrng_es_cpu: obtained")
	then
		echo_pass "CPU RNG: used for seeding"
	else
		echo_fail "CPU RNG: not used for seeding"
		return
	fi

	verify_entropyrate_boot
	verify_set_entropyrate 1
	verify_set_entropyrate 10
	verify_set_entropyrate 256

	verify_set_entropyrate_overflow 257
	verify_set_entropyrate_overflow 1000
	verify_set_entropyrate_overflow 16384
}

$(in_hypervisor)
if [ $? -eq 1 ]
then
	case $(read_cmd) in
		"test1")
			verify_cpu
			;;
		*)
			echo_fail "Test $1 not found"
			;;
	esac
else
	$(check_kernel_config "CONFIG_LRNG_CPU=y")
	if [ $? -ne 0 ]
	then
		echo_deact "CPU RNG: tests skipped"
		exit
	fi

	$(check_kernel_config "CONFIG_LRNG_RUNTIME_ES_CONFIG=y")
	if [ $? -ne 0 ]
	then
		echo_deact "CPU RNG: tests skipped"
		exit
	fi

	$(check_kernel_config "CONFIG_LRNG_JENT=y")
	if [ $? -ne 0 ]
	then
		echo_deakt "CPU RNG: CPU RNG not enabled"
		exit
	fi

	#
	# Validating FIPS mode
	#
	write_cmd "test1"
	execvirt $(full_scriptname $0) "fips=1 lrng_es_jent.jent_entropy=256 lrng_es_cpu.cpu_entropy=256"

	#
	# Validating non-FIPS mode
	#
	write_cmd "test1"
	execvirt $(full_scriptname $0) "lrng_es_jent.jent_entropy=256 lrng_es_cpu.cpu_entropy=256"

	#
	# Validating NTG mode
	#
	write_cmd "test1"
	execvirt $(full_scriptname $0) "lrng_es_mgr.ntg1=1 lrng_es_jent.jent_entropy=256 lrng_es_cpu.cpu_entropy=256"

	#
	# Validating NTG and FIPS mode
	#
	write_cmd "test1"
	execvirt $(full_scriptname $0) "fips=1 lrng_es_mgr.ntg1=1 lrng_es_jent.jent_entropy=256 lrng_es_cpu.cpu_entropy=256"
fi
