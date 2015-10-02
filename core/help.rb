require_relative '../core/out'


class Help

def Help.display
  $out.out <<-EOF
mdbci [option] <show | setup | generate>

-h, --help:
  Shows this help screen

-t, --template [config file]:
  Uses [config file] for running instance. By default 'instance.json' will be used as config template.

-b, --boxes [boxes file]:
  Uses [boxes file] for existing boxes. By default 'boxes.json'  will be used as boxes file.

-w, --override
  Override previous configuration

-c, --command
  Set command to run for sudo or ssh clause

-s, --silent
  Keep silence, output only requested info or nothing if not available

-r, --repo-dir
  Change default place for repo.d

COMMANDS:
  show [boxes, platforms, versions, network, repos [config | config/node], keyfile config/node ]
  generate
  setup [boxes]
  sudo --command 'command arguments' config/node
  ssh --command 'command arguments' config/node

EXAMPLES:
  mdbci sudo --command "tail /var/log/anaconda.syslog" T/node0 --silent
  mdbci ssh --command "cat script.sh" T/node1
  mdbci --repo-dir /home/testbed/config/repos show repos

  EOF

end

end
