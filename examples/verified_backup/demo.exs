ExUnit.start(autorun: false)

directory =
  Path.join(
    System.tmp_dir!(),
    "magpie-verified_backup-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  )

File.mkdir_p!(directory)

try do
  VerifiedBackup.BackupScenario.run(directory, &IO.puts/1)
after
  File.rm_rf!(directory)
end
