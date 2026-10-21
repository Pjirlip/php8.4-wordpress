<?php 

// Some PHP 8 Feature:

readonly class Post
{
    public function __construct(
        public string $title, 
        public Author $author,
        public string $body,
        public DateTime $publishedAt,
    ) {}
};

phpinfo();


?>
