[[ $- != *i* ]] && return

export XMODIFIERS=@im=fcitx

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

alias pac\?="sudo pacman -Qs "
alias pac+="sudo pacman -S "
alias pac-="sudo pacman -R "
alias pac++="sudo pacman -Sy "

export PS1="[\w] "