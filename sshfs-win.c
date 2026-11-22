/**
 * sshfs-win.c
 *
 * Copyright 2015-2021 Bill Zissimopoulos
 */
/*
 * This file is part of SSHFS-Win.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include <assert.h>
#include <ctype.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __CYGWIN__
#include <sys/cygwin.h>
#include <windows.h>
#endif

static char sshfs[PATH_MAX] = "/usr/bin/sshfs.exe";
static char ssh_exe[PATH_MAX] = "/usr/bin/ssh.exe";

/*
 * WinFsp's fuse_opt_parse() consumes one backslash in every -o value before
 * sshfs sees it. So a space needs TWO backslashes (one is eaten, one survives
 * for sshfs's tokenize_on_space()); a comma needs ONE (WinFsp uses commas as
 * option separators, and sshfs's tokenizer does not escape them).
 */
static void escape_spaces(const char *src, char *dst, size_t size)
{
    size_t j = 0;
    for (; *src && j + 3 < size; src++)
    {
        if (' ' == *src)
        {
            dst[j++] = '\\';
            dst[j++] = '\\';
        }
        else if (',' == *src)
            dst[j++] = '\\';
        dst[j++] = *src;
    }
    dst[j] = '\0';
}

/*
 * The upstream launcher hardcodes /usr/bin/sshfs.exe and /usr/bin/ssh.exe.
 * That only works when Cygwin's root is the install directory. Resolve both
 * next to this executable instead.
 */
/*
 * Cygwin expands '*' in argv before main(), which destroys WinFsp's Mount
 * Manager mountpoint. Setting noglob here is too late for this process, but
 * it is inherited by the sshfs child we execve below.
 */
static void disable_glob(void)
{
    const char *v = getenv("CYGWIN");
    char buf[256];
    if (v && strstr(v, "noglob"))
        return;
    if (v)
        snprintf(buf, sizeof buf, "%s noglob", v);
    else
        snprintf(buf, sizeof buf, "noglob");
    setenv("CYGWIN", buf, 1);
}

/*
 * Cygwin's cygwin_create_path() collapses paths under its own root to
 * /usr/bin/..., so build the /cygdrive/<letter>/ form directly.
 */
static char *win_to_posix(const char *win)
{
    size_t len;
    char *out;
    size_t i, j = 0;

    if (!win[0] || win[1] != ':' || win[2] != '\\')
        return 0;
    len = strlen(win);
    out = malloc(len + sizeof "/cygdrive/x/");
    if (!out)
        return 0;
    j = (size_t) snprintf(out, len + sizeof "/cygdrive/x/",
        "/cygdrive/%c/", tolower((unsigned char) win[0]));
    for (i = 3; win[i] && j < len + sizeof "/cygdrive/x/" - 1; i++)
        out[j++] = '\\' == win[i] ? '/' : win[i];
    out[j] = '\0';
    return out;
}

static void find_sshfs(void)
{
#ifdef __CYGWIN__
    char winpath[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, winpath, sizeof winpath);
    if (n > 0 && n < sizeof winpath)
    {
        char *path = win_to_posix(winpath);
        if (path)
        {
            char *slash = strrchr(path, '/');
            if (slash)
            {
                size_t dirlen = (size_t)(slash - path) + 1;
                if (dirlen + sizeof "sshfs.exe" <= sizeof sshfs)
                {
                    memcpy(sshfs, path, dirlen);
                    strcpy(sshfs + dirlen, "sshfs.exe");
                }
                if (dirlen + sizeof "ssh.exe" <= sizeof ssh_exe)
                {
                    memcpy(ssh_exe, path, dirlen);
                    strcpy(ssh_exe + dirlen, "ssh.exe");
                }
            }
            free(path);
        }
    }
#else
    (void) win_to_posix;
#endif
}

#if 0
#define execve pr_execv
static void pr_execv(const char *path, char *argv[], ...)
{
    fprintf(stderr, "%s\n", path);
    for (; 0 != *argv; argv++)
        fprintf(stderr, "    %s\n", *argv);
}
#endif

static void usage(void)
{
    fprintf(stderr,
        "usage: sshfs-win cmd SSHFS_COMMAND_LINE\n"
        "    SSHFS_COMMAND_LINE  command line to pass to sshfs\n"
        "\n"
        "usage: sshfs-win svc PREFIX X: [LOCUSER] [SSHFS_OPTIONS]\n"
        "    PREFIX              Windows UNC prefix (note single backslash)\n"
        "                        \\sshfs[.SUFFIX]\\[LOCUSER=]REMUSER@HOST[!PORT][\\PATH]\n"
        "                        \\sshfs[.SUFFIX]\\alias[\\PATH]\n"
        "                        sshfs: remote user home dir\n"
        "                        sshfs.r: remote root dir\n"
        "                        sshfs.k: remote user home dir with key authentication\n"
        "                        sshfs.kr: remote root dir with key authentication\n"
        "    LOCUSER             local user (DOMAIN+USERNAME)\n"
        "    REMUSER             remote user\n"
        "    HOST                remote host\n"
        "    PORT                remote port\n"
        "    PATH                remote path (relative to remote home or root)\n"
        "    X:                  mount drive\n"
        "    SSHFS_OPTIONS       additional options to pass to SSHFS\n");
    exit(2);
}

static void concat_argv(char *dst[], char *src[])
{
    for (; 0 != *dst; dst++)
        ;
    for (; 0 != (*dst = *src); dst++, src++)
        ;
}

static void opt_escape(const char *opt, char *escaped, size_t size)
{
    const char *p = opt;
    char *q = escaped, *endq = escaped + size;
    for (; *p && endq > q + 1; p++, q++)
    {
        if (',' == *p || '\\' == *p)
            *q++ = '\\';
        *q = *p;
    }
    *q = '\0';
}

static int is_mountpoint_arg(const char *s)
{
    size_t n = strlen(s);
    if (n == 2 && s[1] == ':' && isalpha((unsigned char) s[0]))
        return 1;
    /* \\.\X: Mount Manager form */
    if (n == 6 && '\\' == s[0] && '\\' == s[1] &&
        ('.' == s[2] || '?' == s[2]) && '\\' == s[3] && ':' == s[5])
        return 1;
    return 0;
}

static uint32_t reg_get(const char *cls, const char *name)
{
    char regpath[256];
    int regfd;
    uint32_t value = -1;

    snprintf(regpath, sizeof regpath,
        "/proc/registry32/HKEY_LOCAL_MACHINE/Software/WinFsp/Services/%s/%s", cls, name);

    regfd = open(regpath, O_RDONLY);
    if (-1 != regfd)
    {
        if (sizeof value != read(regfd, &value, sizeof value))
            value = -1;
        close(regfd);
    }

    return value;
}

static int fixenv_and_execv(const char *path, char **argv)
{
    static char *default_environ[] = { "PATH=/bin", 0 };
    extern char **environ;
    char **oldenv, **oldp;
    char **newenv, **newp;
    size_t len, siz;
    int res;

    oldenv = environ;

    siz = 0;
    for (oldp = oldenv; *oldp; oldp++)
    {
        if (0 == strncmp(*oldp, "PATH=", 5))
        {
            len = strlen(*oldp + 5);
            siz += len + sizeof "PATH=/usr/bin:";
        }
        else
        {
            len = strlen(*oldp);
            siz += len + 1;
        }
    }
    oldp++;

    newenv = malloc((oldp - oldenv) * sizeof(char *) + siz);
    if (0 != newenv)
    {
        siz = (oldp - oldenv) * sizeof(char *);
        for (oldp = oldenv, newp = newenv; *oldp; oldp++, newp++)
        {
            *newp = (char *)newenv + siz;
            if (0 == strncmp(*oldp, "PATH=", 5))
            {
                len = strlen(*oldp + 5);
                siz += len + sizeof "PATH=/usr/bin:";
                memcpy(*newp, "PATH=/usr/bin:", sizeof "PATH=/usr/bin:" - 1);
                memcpy(*newp + sizeof "PATH=/usr/bin:" - 1, *oldp + 5, len + 1);
            }
            else
            {
                len = strlen(*oldp);
                siz += len + 1;
                memcpy(*newp, *oldp, len + 1);
            }
        }
        *newp = 0;
    }
    else
    {
        newenv = default_environ;
        newp = newenv + 1;
    }

#if 1
    res = execve(path, argv, newenv);
#else
    char **p;
    for (p = newenv; *p; p++)
        printf("%s\n", *p);
    assert(newp == p);
#endif

    if (newenv != default_environ)
        free(newenv);

    return res;
}

static int do_cmd(int argc, char *argv[])
{
    if (200 < argc)
        usage();

    char *sshfs_argv[256] =
    {
        sshfs, 0,
    };

    concat_argv(sshfs_argv, argv + 1);

    fixenv_and_execv(sshfs, sshfs_argv);
    return 1;
}

static int do_svc(int argc, char *argv[])
{
/* Upstream sshfs 3.7.x removed -o rellinks; transform_symlinks +
 * no_contain_symlinks is the documented replacement. */
#define SSHFS_ARGS                      \
    "-f",                               \
    "-otransform_symlinks",             \
    "-ono_contain_symlinks",            \
    "-ofstypename=SSHFS",               \
    "-oUserKnownHostsFile=/dev/null",   \
    "-oStrictHostKeyChecking=no"

    if (3 > argc || 200 < argc)
        usage();

    struct passwd *passwd = 0;
    char escaped[1024];
    char idmap[64], authmeth[64 + 1024], volpfx[256], remote[256];
    char portopt[sizeof escaped + 16];
    char sshesc[2 * PATH_MAX + 32];
    char sshcmd[sizeof sshesc + 16];
    char *cls, *locuser, *locuser_nodom, *userhost, *port, *root, *path, *p;
    const char *mount = argv[2];
    int globbed_mount = 0;

    snprintf(volpfx, sizeof volpfx, "--VolumePrefix=%s", argv[1]);
    escape_spaces(ssh_exe, sshesc, sizeof sshesc);
    snprintf(sshcmd, sizeof sshcmd, "-ossh_command=%s", sshesc);

    /* A literal '*' mountpoint may have been globbed by the Cygwin CRT. */
    if (strcmp(mount, "*") != 0 && !is_mountpoint_arg(mount))
    {
        globbed_mount = 1;
        mount = "*";
    }

    /* translate backslash to forward slash */
    for (p = argv[1]; *p; p++)
        if ('\\' == *p)
            *p = '/';

    /* skip class name */
    p = argv[1];
    while ('/' == *p)
        p++;
    cls = p;
    while (*p && '/' != *p)
        p++;
    if (*p)
        *p++ = '\0';
    while ('/' == *p)
        p++;
    root = 1 == reg_get(cls, "sshfs.rootdir") ? "/" : "";

    /* parse instance name (syntax: [locuser=]user@host[!port]) */
    locuser = locuser_nodom = 0;
    userhost = p;
    port = 0;
    while (*p && '/' != *p)
    {
        if ('=' == *p)
        {
            *p = '\0';
            locuser = userhost;
            userhost = p + 1;
        }
        else if ('!' == *p)
        {
            *p = '\0';
            port = p + 1;
        }
        p++;
    }
    if (*p)
        *p++ = '\0';
    path = p;
    if (port != 0)
    {
        opt_escape(port, escaped, sizeof escaped);
        snprintf(portopt, sizeof portopt, "-oPort=%s", escaped);
    }
    else
    {
        portopt[0] = '\0';
    }
    snprintf(remote, sizeof remote, "%s:%s%s", userhost, root, path);

    /* get local user name */
    if (0 == locuser)
    {
        if (3 >= argc)
        {
            p = userhost;
            while (*p && '@' != *p)
                p++;
            if (*p)
            {
                *p = '\0';
                locuser = userhost;
            }
        }
        else
        {
            locuser = argv[3];
            /* the Cygwin runtime does not remove double quotes around args with non-ASCII chars */
            if (locuser[0] == '"')
            {
                size_t len = strlen(locuser);
                if (len >= 2 && locuser[len - 1] == '"')
                {
                    locuser[len - 1] = '\0';    /* remove the trailing quote... */
                    ++locuser;                  /* ...and the heading one       */
                }
            }
            /* translate backslash to '+' */
            for (p = locuser; *p; p++)
                if ('\\' == *p)
                {
                    *p = '+';
                    locuser_nodom = p + 1;
                }
        }
    }

    snprintf(idmap, sizeof idmap, "-ouid=-1,gid=-1");
    if (0 != locuser)
    {
        /* get uid/gid from local user name */
        passwd = getpwnam(locuser);
        if (0 == passwd && 0 != locuser_nodom)
            passwd = getpwnam(locuser_nodom);
        if (0 != passwd)
            snprintf(idmap, sizeof idmap, "-ouid=%d,gid=%d", passwd->pw_uid, passwd->pw_gid);
    }

    if (1 == reg_get(cls, "Credentials"))
        snprintf(authmeth, sizeof authmeth,
            "-opassword_stdin,password_stdout");
    else if (0 != passwd)
    {
        opt_escape(passwd->pw_dir, escaped, sizeof escaped);
        snprintf(authmeth, sizeof authmeth,
            "-oPreferredAuthentications=publickey,IdentityFile=\"%s/.ssh/id_rsa\"", escaped);
    }
    else
        snprintf(authmeth, sizeof authmeth,
            "-oPreferredAuthentications=publickey");

    char *sshfs_argv[256] =
    {
        sshfs, SSHFS_ARGS, sshcmd, idmap, authmeth, volpfx, portopt, remote, (char *) mount, 0,
    };

    if ('\0' == portopt[0])
    {
        /* if not passing a port option, remove it from sshfs_argv */
        int portopt_idx = 0;
        while (sshfs_argv[portopt_idx] != portopt)
            portopt_idx++;
        while (sshfs_argv[portopt_idx] != 0)
        {
            sshfs_argv[portopt_idx] = sshfs_argv[portopt_idx + 1];
            portopt_idx++;
        }
    }

    /* Glob-expanded mountpoint garbage must not become sshfs options. */
    if (4 <= argc && !globbed_mount)
        concat_argv(sshfs_argv, argv + 4);

    fixenv_and_execv(sshfs, sshfs_argv);
    return 1;

#undef SSHFS_ARGS
}

int main(int argc, char *argv[])
{
    const char *mode = argv[1];

    disable_glob();
    find_sshfs();

    if (0 != mode && 0 == strcmp("cmd", mode))
        return do_cmd(argc - 1, argv + 1);
    if (0 != mode && 0 == strcmp("svc", mode))
        return do_svc(argc - 1, argv + 1);

    usage();
    return 1;
}
