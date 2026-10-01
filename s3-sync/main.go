package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"time"
)

const usage = `usage: s3-sync <command> [arguments]

  sync --dir DIR [--status FILE]   upload the dumps the bucket lacks, then prune it
  ls [--db DB]                     list the bucket: key, bytes, size, taken, tier
  get KEY                          write one object to stdout
  latest DB                        print the key of the database's newest dump

Settings come from the S3_* environment variables.`

func main() {
	os.Exit(run(context.Background(), os.Args[1:], os.Getenv, os.Stdout, os.Stderr, NewMinioStorage, time.Now))
}

// run is main without the process. Exit codes: 0 ok, 1 failed, 2 bad usage or settings.
func run(ctx context.Context, args []string, getenv func(string) string, out, errOut io.Writer,
	open func(Env) (Storage, error), now func() time.Time) int {
	if len(args) == 0 {
		fmt.Fprintln(errOut, usage)
		return 2
	}
	cmd := map[string]func(context.Context, []string, Env, Storage, io.Writer, io.Writer, func() time.Time) int{
		"sync": cmdSync, "ls": cmdList, "get": cmdGet, "latest": cmdLatest,
	}[args[0]]
	if cmd == nil {
		fmt.Fprintln(errOut, usage)
		return 2
	}
	env, err := LoadEnv(getenv)
	if err != nil {
		fmt.Fprintf(errOut, "s3-sync: %v\n", err)
		return 2
	}
	st, err := open(env)
	if err != nil {
		fmt.Fprintf(errOut, "s3-sync: %v\n", err)
		return 2
	}
	return cmd(ctx, args[1:], env, st, out, errOut, now)
}

func cmdSync(ctx context.Context, args []string, env Env, st Storage, out, errOut io.Writer, now func() time.Time) int {
	fs := flag.NewFlagSet("sync", flag.ContinueOnError)
	fs.SetOutput(errOut)
	dir := fs.String("dir", "", "the backup folder")
	status := fs.String("status", "", "the status file to write")
	if err := fs.Parse(args); err != nil || *dir == "" {
		fmt.Fprintln(errOut, "s3-sync sync: --dir is required")
		return 2
	}
	s := Settings{Location: env.Location(), Prefix: env.Prefix, Retention: env.Retention,
		Prune: env.Prune, AllowUnencrypted: env.AllowUnencrypted}
	res := RunSync(ctx, st, s, *dir, now(), out, errOut)
	if *status != "" {
		if err := WriteStatus(*status, res.OK, now(), res.Objects); err != nil {
			fmt.Fprintf(errOut, "⚠️ off-site: cannot write %s (%v).\n", *status, err)
			return 1
		}
	}
	if !res.OK {
		return 1
	}
	return 0
}

func cmdList(ctx context.Context, args []string, env Env, st Storage, out, errOut io.Writer, now func() time.Time) int {
	fs := flag.NewFlagSet("ls", flag.ContinueOnError)
	fs.SetOutput(errOut)
	db := fs.String("db", "", "only this database's dumps")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	listing, err := st.List(ctx, ListPrefix(env.Prefix))
	if err != nil {
		fmt.Fprintf(errOut, "s3-sync: cannot list %s (%v)\n", env.Location(), err)
		return 1
	}
	sort.Slice(listing, func(i, j int) bool { return listing[i].Key < listing[j].Key })
	t := now()
	for _, o := range listing {
		name, stamp, ok := ParseStamped(baseName(o.Key))
		// Only an object at <prefix>/<db>/<name> is one of this deployment's dumps.
		ok = ok && o.Key == ObjectKey(env.Prefix, name, baseName(o.Key))
		if !ok {
			name = ""
		}
		if *db != "" && name != *db {
			continue
		}
		taken, tier := "-", "-"
		if ok {
			taken = stamp.Format("2006-01-02 15:04:05")
			_, tier = env.Retention.Keep(stamp, t)
		}
		fmt.Fprintf(out, "%s\t%d\t%s\t%s\t%s\n", o.Key, o.Size, humanSize(o.Size), taken, tier)
	}
	return 0
}

func cmdGet(ctx context.Context, args []string, env Env, st Storage, out, errOut io.Writer, _ func() time.Time) int {
	if len(args) != 1 {
		fmt.Fprintln(errOut, "usage: s3-sync get KEY")
		return 2
	}
	if err := st.Get(ctx, args[0], out); err != nil {
		fmt.Fprintf(errOut, "s3-sync: cannot read %s from %s (%v)\n", args[0], env.Location(), err)
		return 1
	}
	return 0
}

func cmdLatest(ctx context.Context, args []string, env Env, st Storage, out, errOut io.Writer, _ func() time.Time) int {
	if len(args) != 1 {
		fmt.Fprintln(errOut, "usage: s3-sync latest DB")
		return 2
	}
	listing, err := st.List(ctx, ListPrefix(env.Prefix)+args[0]+"/")
	if err != nil {
		fmt.Fprintf(errOut, "s3-sync: cannot list %s (%v)\n", env.Location(), err)
		return 1
	}
	var best *RemoteObject
	for _, o := range stampedObjects(env.Prefix, listing) {
		if o.DB == args[0] && (best == nil || o.Stamp.After(best.Stamp)) {
			candidate := o
			best = &candidate
		}
	}
	if best == nil {
		return 1
	}
	fmt.Fprintln(out, best.Key)
	return 0
}
