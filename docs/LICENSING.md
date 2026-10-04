# Source license options

Meshenger's own source remains **unlicensed** by the owner's choice. No root `LICENSE` has been added. Publishing source publicly does not automatically grant general permission to reuse or distribute it; GitHub's terms still permit viewing and forking through GitHub. Dependency licenses remain separate. [GitHub licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository).

These are common choices for a future decision, not licenses currently applied to Meshenger:

| Choice | What downstream users may do | Main conditions |
| --- | --- | --- |
| [MIT](https://opensource.org/license/mit) | Use, modify, sell and redistribute, including closed-source versions. | Keep the copyright and permission notice. Short and permissive; no express patent grant. |
| [BSD 3-Clause](https://opensource.org/license/bsd-3-clause) | Broad reuse, including commercial and closed-source versions. | Preserve notices; names of contributors/copyright holders cannot be used to endorse derived products without permission. |
| [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) | Broad reuse, including commercial and closed-source versions, with an explicit contributor patent grant. | Include the license, retain relevant notices, mark changed files, and carry required NOTICE attributions. Patent rights can terminate for specified patent litigation. |
| [MPL 2.0](https://www.mozilla.org/en-US/MPL/2.0/FAQ/) | Combine covered code with separate proprietary files. | When distributing, make the covered files and their modifications available as MPL source. Copyleft operates at the file level. |
| [LGPL 3.0](https://www.gnu.org/licenses/lgpl-3.0.html) | Use the covered library within applications with different licenses. | Library modifications remain covered; distribution must preserve users' ability to modify/replace the library, which can require relinking materials. More suitable for a library than a whole app. |
| [GPL 3.0](https://www.gnu.org/licenses/gpl-3.0.html) | Use, modify and sell the software. | When conveying a covered program, provide corresponding source under GPL terms. Covered combined/derivative programs must preserve those freedoms; private modifications alone do not require public release. |
| [AGPL 3.0](https://www.gnu.org/licenses/agpl-3.0.html) | Use, modify and sell, with GPL-style copyleft. | Also requires a modified program to offer corresponding source to users interacting with it remotely over a network. Most relevant where hosted services matter. |

MIT and Apache 2.0 allow commercial forks to remain closed source. MPL requires changes to the covered files to stay available when distributed; GPL requires covered redistributed programs to remain open; AGPL adds a network-interaction source obligation for modified programs. None is a prohibition on charging money.

For Meshenger, MIT would prioritize a simple permissive license; Apache 2.0 would prioritize permissive reuse with explicit patent terms; GPL 3.0 would prioritize keeping covered distributed forks open. The current decision is to choose none of them yet.

Before applying a future license, check ownership of contributions and compatibility with the resolved dependencies. A Meshenger license cannot override a dependency's separate terms. FlutterBluePlus has been removed from the current dependency graph; earlier builds containing it keep its separate commercial-use terms. See [the removal record](FLUTTER_BLUE_PLUS_REMOVAL.md).
