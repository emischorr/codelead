defmodule CodeLeadWeb.ForgeLinksTest do
  use ExUnit.Case, async: true

  alias CodeLead.Git
  alias CodeLeadWeb.ForgeLinks

  test "GitHub blob URLs, with and without a line anchor" do
    forge = Git.forge("https://github.com/acme/shop.git")

    assert ForgeLinks.file_url(forge, "main", "lib/pay.ex") ==
             "https://github.com/acme/shop/blob/main/lib/pay.ex"

    assert ForgeLinks.file_url(forge, "main", "lib/pay.ex:42") ==
             "https://github.com/acme/shop/blob/main/lib/pay.ex#L42"
  end

  test "GitLab blob URLs use the /-/blob/ convention" do
    forge = Git.forge("git@gitlab.com:acme/shop.git")

    assert ForgeLinks.file_url(forge, "develop", "app/models/user.rb:7") ==
             "https://gitlab.com/acme/shop/-/blob/develop/app/models/user.rb#L7"
  end

  test "an unknown forge — including self-hosted GitLab — yields no link" do
    assert Git.forge("https://git.example.com/acme/shop.git") == :other
    assert ForgeLinks.file_url(:other, "main", "lib/pay.ex:42") == nil
  end

  test "a trailing colon segment that is not a number stays part of the path" do
    forge = Git.forge("https://github.com/acme/shop.git")

    assert ForgeLinks.file_url(forge, "main", "lib/pay.ex:notes") ==
             "https://github.com/acme/shop/blob/main/lib/pay.ex:notes"
  end
end
