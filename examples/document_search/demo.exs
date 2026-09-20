ExUnit.start(autorun: false)

directory =
  Path.join(
    System.tmp_dir!(),
    "magpie-search-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  )

File.mkdir_p!(directory)

try do
  DocumentSearch.SearchScenario.run(directory, &IO.puts/1)
after
  File.rm_rf!(directory)
end
