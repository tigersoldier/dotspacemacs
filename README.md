# Caibin Chen's Spacemacs private packages

This is my Spacemacs configs. Its main purposes is for my own convenience to setup multiple devices.

## Prequisite

*  Install [Emacs][emacs]

*  Install [Spacemacs][spacemacs]:

        git clone https://github.com/syl20bnr/spacemacs ~/.emacs.d
      
## Install the private packages

```shell
# Remove the existing private directory
rm -r ~/.emacs.d/private

# Clone this repo
git clone git@github.com:tigersoldier/dotspacemacs.git ~/.emacs.d/private

# Symlink .spacemacs
ln -s ~/.emacs.d/private/init.el ~/.spacemacs
```
