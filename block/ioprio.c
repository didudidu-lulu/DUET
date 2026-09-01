// SPDX-License-Identifier: GPL-2.0
/*
 * fs/ioprio.c
 *
 * Copyright (C) 2004 Jens Axboe <axboe@kernel.dk>
 *
 * Helper functions for setting/querying io priorities of processes. The
 * system calls closely mimmick getpriority/setpriority, see the man page for
 * those. The prio argument is a composite of prio class and prio data, where
 * the data argument has meaning within that class. The standard scheduling
 * classes have 8 distinct prio levels, with 0 being the highest prio and 7
 * being the lowest.
 *
 * IOW, setting BE scheduling class with prio 2 is done ala:
 *
 * unsigned int prio = (IOPRIO_CLASS_BE << IOPRIO_CLASS_SHIFT) | 2;
 *
 * ioprio_set(PRIO_PROCESS, pid, prio);
 *
 * See also Documentation/block/ioprio.rst
 *
 */
#include <linux/gfp.h>
#include <linux/kernel.h>
#include <linux/ioprio.h>
#include <linux/cred.h>
#include <linux/blkdev.h>
#include <linux/capability.h>
#include <linux/syscalls.h>
#include <linux/security.h>
#include <linux/pid_namespace.h>
#include <linux/uaccess.h>
#include <linux/limits.h>
#include <linux/string.h>
#include <linux/sched/task.h>

#include "elevator.h"
#include "bfq-iosched.h"

int ioprio_check_cap(int ioprio)
{
	int class = IOPRIO_PRIO_CLASS(ioprio);
	int level = IOPRIO_PRIO_LEVEL(ioprio);

	switch (class) {
		case IOPRIO_CLASS_RT:
			/*
			 * Originally this only checked for CAP_SYS_ADMIN,
			 * which was implicitly allowed for pid 0 by security
			 * modules such as SELinux. Make sure we check
			 * CAP_SYS_ADMIN first to avoid a denial/avc for
			 * possibly missing CAP_SYS_NICE permission.
			 */
			if (!capable(CAP_SYS_ADMIN) && !capable(CAP_SYS_NICE))
				return -EPERM;
			fallthrough;
			/* rt has prio field too */
		case IOPRIO_CLASS_BE:
			if (level >= IOPRIO_NR_LEVELS)
				return -EINVAL;
			break;
		case IOPRIO_CLASS_IDLE:
			break;
		case IOPRIO_CLASS_NONE:
			if (level)
				return -EINVAL;
			break;
		case IOPRIO_CLASS_INVALID:
		default:
			return -EINVAL;
	}

	return 0;
}

SYSCALL_DEFINE3(ioprio_set, int, which, int, who, int, ioprio)
{
	struct task_struct *p, *g;
	struct user_struct *user;
	struct pid *pgrp;
	kuid_t uid;
	int ret;

	ret = ioprio_check_cap(ioprio);
	if (ret)
		return ret;

	ret = -ESRCH;
	rcu_read_lock();
	switch (which) {
		case IOPRIO_WHO_PROCESS:
			if (!who)
				p = current;
			else
				p = find_task_by_vpid(who);
			if (p)
				ret = set_task_ioprio(p, ioprio);
			break;
		case IOPRIO_WHO_PGRP:
			if (!who)
				pgrp = task_pgrp(current);
			else
				pgrp = find_vpid(who);

			read_lock(&tasklist_lock);
			do_each_pid_thread(pgrp, PIDTYPE_PGID, p) {
				ret = set_task_ioprio(p, ioprio);
				if (ret) {
					read_unlock(&tasklist_lock);
					goto out;
				}
			} while_each_pid_thread(pgrp, PIDTYPE_PGID, p);
			read_unlock(&tasklist_lock);

			break;
		case IOPRIO_WHO_USER:
			uid = make_kuid(current_user_ns(), who);
			if (!uid_valid(uid))
				break;
			if (!who)
				user = current_user();
			else
				user = find_user(uid);

			if (!user)
				break;

			for_each_process_thread(g, p) {
				if (!uid_eq(task_uid(p), uid) ||
				    !task_pid_vnr(p))
					continue;
				ret = set_task_ioprio(p, ioprio);
				if (ret)
					goto free_uid;
			}
free_uid:
			if (who)
				free_uid(user);
			break;
		default:
			ret = -EINVAL;
	}

out:
	rcu_read_unlock();
	return ret;
}

static int get_task_ioprio(struct task_struct *p)
{
	int ret;

	ret = security_task_getioprio(p);
	if (ret)
		goto out;
	task_lock(p);
	ret = __get_task_ioprio(p);
	task_unlock(p);
out:
	return ret;
}

/*
 * Return raw IO priority value as set by userspace. We use this for
 * ioprio_get(pid, IOPRIO_WHO_PROCESS) so that we keep historical behavior and
 * also so that userspace can distinguish unset IO priority (which just gets
 * overriden based on task's nice value) from IO priority set to some value.
 */
static int get_task_raw_ioprio(struct task_struct *p)
{
	int ret;

	ret = security_task_getioprio(p);
	if (ret)
		goto out;
	task_lock(p);
	if (p->io_context)
		ret = p->io_context->ioprio;
	else
		ret = IOPRIO_DEFAULT;
	task_unlock(p);
out:
	return ret;
}

static int ioprio_best(unsigned short aprio, unsigned short bprio)
{
	return min(aprio, bprio);
}

SYSCALL_DEFINE2(ioprio_get, int, which, int, who)
{
	struct task_struct *g, *p;
	struct user_struct *user;
	struct pid *pgrp;
	kuid_t uid;
	int ret = -ESRCH;
	int tmpio;

	rcu_read_lock();
	switch (which) {
		case IOPRIO_WHO_PROCESS:
			if (!who)
				p = current;
			else
				p = find_task_by_vpid(who);
			if (p)
				ret = get_task_raw_ioprio(p);
			break;
		case IOPRIO_WHO_PGRP:
			if (!who)
				pgrp = task_pgrp(current);
			else
				pgrp = find_vpid(who);
			read_lock(&tasklist_lock);
			do_each_pid_thread(pgrp, PIDTYPE_PGID, p) {
				tmpio = get_task_ioprio(p);
				if (tmpio < 0)
					continue;
				if (ret == -ESRCH)
					ret = tmpio;
				else
					ret = ioprio_best(ret, tmpio);
			} while_each_pid_thread(pgrp, PIDTYPE_PGID, p);
			read_unlock(&tasklist_lock);

			break;
		case IOPRIO_WHO_USER:
			uid = make_kuid(current_user_ns(), who);
			if (!who)
				user = current_user();
			else
				user = find_user(uid);

			if (!user)
				break;

			for_each_process_thread(g, p) {
				if (!uid_eq(task_uid(p), user->uid) ||
				    !task_pid_vnr(p))
					continue;
				tmpio = get_task_ioprio(p);
				if (tmpio < 0)
					continue;
				if (ret == -ESRCH)
					ret = tmpio;
				else
					ret = ioprio_best(ret, tmpio);
			}

			if (who)
				free_uid(user);
			break;
		default:
			ret = -EINVAL;
	}

	rcu_read_unlock();
	return ret;
}

/**
 * 功能描述：设置进程的优先级覆盖标志
 * 用法：ioprio_override [PID]，它将标记PID对应的进程为突发进程，该进程发出的所有io请求将被标记为burst io。
 * 注意：该标记与操作系统原始的ioprio无关，为独立的标记
 * @param 参数1 PID
 * @return 0成功，-1失败
 */
SYSCALL_DEFINE1(ioprio_override, int, pid)
{
	struct task_struct *p;
	int ret = 0;
	bool remote = false;

	pr_info("ioprio_override: request pid=%d caller_pid=%d\n",
		pid, task_pid_nr(current));

	rcu_read_lock();
	if (!pid) {
		p = current;
	} else {
		p = find_task_by_vpid(pid);
		if (p) {
			get_task_struct(p);
			remote = true;
		}
	}

	if (!p) {
		pr_err("ioprio_override: target pid=%d not found\n", pid);
		ret = -ESRCH;
		rcu_read_unlock();
		return ret;
	}
	rcu_read_unlock();

	task_lock(p);
	if (!(p->flags & PF_EXITING)) {
		p->ioprio_override = true;
		pr_info("ioprio_override: applied to pid=%d comm=%s\n",
			task_pid_nr(p), p->comm);
	} else {
		pr_err("ioprio_override: pid=%d is exiting\n", task_pid_nr(p));
		ret = -ESRCH;
	}
	task_unlock(p);

	if (!ret)
		ioprio_override_monitor_enqueue(p);

	if (remote)
		put_task_struct(p);

	if (ret)
		pr_err("ioprio_override: failed pid=%d ret=%d\n", pid, ret);
	return ret;
}

SYSCALL_DEFINE4(bdev_set_bytes, const char __user *, dev_name, int, enable,
		unsigned int, bfq_high_bytes, unsigned int, bfq_low_bytes)
{
	char *kname;
	dev_t dev;
	struct block_device *bdev;
	struct request_queue *q;
	struct elevator_queue *e;
	struct bfq_data *bfqd;
	int ret;

	pr_info("bdev_set_bytes: request enable=%d high=%u low=%u\n",
		enable, bfq_high_bytes, bfq_low_bytes);

	if (enable != 0 && enable != 1) {
		pr_err("bdev_set_bytes: invalid enable=%d\n", enable);
		return -EINVAL;
	}
	if (bfq_high_bytes < bfq_low_bytes) {
		pr_err("bdev_set_bytes: invalid thresholds high=%u low=%u\n",
			bfq_high_bytes, bfq_low_bytes);
		return -EINVAL;
	}

	kname = strndup_user(dev_name, PATH_MAX);
	if (IS_ERR(kname)) {
		pr_err("bdev_set_bytes: failed to copy device name from userspace\n");
		return PTR_ERR(kname);
	}

	pr_info("bdev_set_bytes: target device=%s\n", kname);

	ret = lookup_bdev(kname, &dev);
	if (ret) {
		pr_err("bdev_set_bytes: lookup_bdev(%s) failed, ret=%d\n", kname,
		       ret);
		goto out_free;
	}

	bdev = blkdev_get_no_open(dev, true);
	if (!bdev) {
		ret = -ENODEV;
		pr_err("bdev_set_bytes: blkdev_get_no_open(%s) failed\n", kname);
		goto out_free;
	}

	q = bdev_get_queue(bdev);
	if (!q || !q->elevator || !q->elevator->type) {
		ret = -EOPNOTSUPP;
		pr_err("bdev_set_bytes: queue/elevator unavailable for %s\n", kname);
		goto out_put;
	}

	e = q->elevator;
	if (strcmp(e->type->elevator_name, "bfq")) {
		ret = -EOPNOTSUPP;
		pr_err("bdev_set_bytes: scheduler is %s, not bfq (dev=%s)\n",
		       e->type->elevator_name, kname);
		goto out_put;
	}

	bfqd = e->elevator_data;
	if (!bfqd) {
		ret = -EOPNOTSUPP;
		pr_err("bdev_set_bytes: bfq elevator_data is NULL (dev=%s)\n", kname);
		goto out_put;
	}

	spin_lock_irq(&bfqd->lock);
	q->io_bytes_enable = !!enable;
	q->io_high_bytes = bfq_high_bytes;
	q->io_low_bytes = bfq_low_bytes;
	spin_unlock_irq(&bfqd->lock);

	pr_info("bdev_set_bytes: applied dev=%s enable=%d high=%u low=%u\n",
		kname, q->io_bytes_enable, q->io_high_bytes, q->io_low_bytes);

	ret = 0;

out_put:
	blkdev_put_no_open(bdev);
out_free:
	kfree(kname);
	return ret;
}

SYSCALL_DEFINE1(bdev_get_bytes, const char __user *, dev_name)
{
	char *kname;
	dev_t dev;
	struct block_device *bdev;
	struct request_queue *q;
	struct elevator_queue *e;
	long bytes;
	long ret;

	pr_info("bdev_get_bytes: request\n");

	kname = strndup_user(dev_name, PATH_MAX);
	if (IS_ERR(kname)) {
		pr_err("bdev_get_bytes: failed to copy device name from userspace\n");
		return PTR_ERR(kname);
	}

	pr_info("bdev_get_bytes: target device=%s\n", kname);

	ret = lookup_bdev(kname, &dev);
	if (ret) {
		pr_err("bdev_get_bytes: lookup_bdev(%s) failed, ret=%ld\n",
		       kname, ret);
		goto out_free;
	}

	bdev = blkdev_get_no_open(dev, true);
	if (!bdev) {
		ret = -ENODEV;
		pr_err("bdev_get_bytes: blkdev_get_no_open(%s) failed\n", kname);
		goto out_free;
	}

	q = bdev_get_queue(bdev);
	if (!q || !q->elevator || !q->elevator->type) {
		ret = -EOPNOTSUPP;
		pr_err("bdev_get_bytes: queue/elevator unavailable for %s\n", kname);
		goto out_put;
	}

	e = q->elevator;
	if (strcmp(e->type->elevator_name, "bfq")) {
		ret = -EOPNOTSUPP;
		pr_err("bdev_get_bytes: scheduler is %s, not bfq (dev=%s)\n",
		       e->type->elevator_name, kname);
		goto out_put;
	}

	bytes = atomic_long_read(&q->io_bytes);
	ret = bytes;
	pr_info("bdev_get_bytes: dev=%s io_bytes=%ld\n", kname, bytes);

out_put:
	blkdev_put_no_open(bdev);
out_free:
	kfree(kname);
	return ret;
}

// 加两个系统调用。设置高优先级，看队列大小
// task结构体里面加上它是高优先级进程
/**
 * 功能描述：简要描述
 *
 * @param 参数1 描述param1
 * @param param2 描述param2
 * @return 返回值说明
 */