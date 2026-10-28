# ~/.bashrc -- Z Alpine Desktop (x86)
case $- in *i*) ;; *) return ;; esac
PS1='\u@\h:\w\$ '
export EDITOR=nano
alias ll='ls -la'
# The serial console is also a machine channel: no bracketed-paste escapes around prompts.
bind 'set enable-bracketed-paste off' 2>/dev/null
